--- Zip archives, written and read.
--
-- An application that keeps backups, exports a folder or hands somebody a
-- bundle needs one archive format, and on Windows that format is zip: it is
-- the one every machine opens without installing anything.
--
--     ok, err = zip.pack "backup.zip", "client/live"
--     names   = zip.entries "backup.zip"
--     bytes   = zip.read "backup.zip", "DBFilesClient/Spell.dbc"
--
-- **DEFLATE comes from the `libdeflate` rock**, which is pure Lua and fast
-- enough under LuaJIT to compress at tens of megabytes a second. The
-- alternatives were a C binding to zlib - which needs a zlib the Windows build
-- does not have - or shelling out to an archiver, which means a vendored
-- executable and a child process at the exact moment the application is
-- shutting down. Neither is worth it for a format this small to write.
--
-- Without the rock everything here still works and stores rather than
-- compresses, the way `util.fs` degrades without luv. An archive that is
-- larger than it should be is a worse archive; one that does not exist is a
-- lost backup.
--
-- **No zip64.** Four gigabytes is the limit, per entry and per archive, and
-- going over it is reported rather than written wrong: a zip64 archive that
-- claims to be a plain one is a file that opens empty in Explorer.
---@module util.zip

fs = require "util.fs"

bit = require "bit"

band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
lshift, rshift = bit.lshift, bit.rshift

byte, char, sub = string.byte, string.char, string.sub

M = {}

-- The whole of the format that is used here. Zip is a sequence of local
-- headers each followed by its bytes, then a directory of the same entries
-- again, then a record saying where that directory is.
LOCAL_SIG = 0x04034b50
CENTRAL_SIG = 0x02014b50
END_SIG = 0x06054b50

STORED = 0
DEFLATED = 8

-- Four gigabytes. Past this the sizes in the headers wrap, and the archive is
-- silently wrong rather than obviously broken.
LIMIT = 0xFFFFFFFF

-- ═══════════════════════════════════════════════════════════════════════════
-- DEFLATE
-- ═══════════════════════════════════════════════════════════════════════════

-- Required lazily and optionally, the way `util.fs` treats luv: one rock
-- failing to install should cost the feature it provides and nothing else.
deflate = nil
deflate_missing = false

---@return table|nil
---@private
compressor = ->
  return deflate if deflate
  return nil if deflate_missing

  ok, result = pcall require, "LibDeflate"
  unless ok
    deflate_missing = true
    return nil

  deflate = result
  deflate

--- Whether entries will actually be compressed.
-- For a caller that wants to say so, and for the suites.
---@return boolean
M.compresses = -> (compressor!) != nil

-- Five rather than nine. On a folder of DBC files level 5 is within three
-- percent of level 9 and ten times faster, and this runs while somebody is
-- waiting for the application to close.
M.LEVEL = 5

-- ═══════════════════════════════════════════════════════════════════════════
-- Numbers on disk
-- ═══════════════════════════════════════════════════════════════════════════

--- Little-endian, the only byte order zip has.
---@param n integer
---@return string
---@private
u16 = (n) -> char (band n, 0xFF), (band (rshift n, 8), 0xFF)

---@param n integer
---@return string
---@private
u32 = (n) -> char (band n, 0xFF), (band (rshift n, 8), 0xFF),
  (band (rshift n, 16), 0xFF), (band (rshift n, 24), 0xFF)

--- Reads a little-endian integer out of a string.
---@param text string
---@param at integer 1-based offset.
---@param width integer Bytes.
---@return integer
---@private
number_at = (text, at, width) ->
  value = 0
  for index = width - 1, 0, -1
    value = value * 256 + ((byte text, at + index) or 0)
  value

-- CRC-32, the reflected IEEE polynomial. Built once, on the first archive.
crc_table = nil

---@return table
---@private
table_of_remainders = ->
  return crc_table if crc_table

  built = {}
  for index = 0, 255
    remainder = index
    for _ = 1, 8
      remainder = if (band remainder, 1) != 0
        bxor 0xEDB88320, (rshift remainder, 1)
      else
        rshift remainder, 1
    built[index] = remainder

  crc_table = built
  built

--- The CRC-32 of a string, as an unsigned number.
--
-- Every entry carries one, and an archiver that finds it wrong refuses the
-- entry - so this is not optional the way the compression is.
---@param text string
---@return integer
M.crc32 = (text) ->
  remainders = table_of_remainders!
  crc = 0xFFFFFFFF

  for index = 1, #text
    crc = bxor (rshift crc, 8),
      remainders[band (bxor crc, (byte text, index)), 0xFF]

  -- Back to unsigned: bit operations in LuaJIT hand back a signed 32-bit
  -- number, and a negative CRC written with `u32` is right by accident and
  -- read back wrong.
  crc = band (bnot crc), 0xFFFFFFFF
  crc < 0 and crc + 4294967296 or crc

--- A timestamp as MS-DOS date and time, which is what zip stores.
-- Two seconds of resolution, and nothing before 1980 - the format has no way
-- to say either, so a date it cannot hold is clamped rather than wrapped.
---@param stamp? integer
---@return integer time, integer date
---@private
dos_stamp = (stamp) ->
  parts = os.date "*t", stamp or os.time!
  year = math.max parts.year, 1980

  time = bor (lshift parts.hour, 11), (lshift parts.min, 5),
    (rshift parts.sec, 1)
  date = bor (lshift (year - 1980), 9), (lshift parts.month, 5), parts.day

  time, date

-- ═══════════════════════════════════════════════════════════════════════════
-- Writing
-- ═══════════════════════════════════════════════════════════════════════════

--- The name an entry goes in under.
-- Forward slashes and no leading one: that is what the format says, and an
-- archive full of backslashes extracts on Windows as files with slashes in
-- their names everywhere else.
---@param name string
---@return string
---@private
entry_name = (name) ->
  cleaned = (tostring name)\gsub "\\", "/"
  cleaned = cleaned\gsub "^/+", ""
  cleaned

--- Writes an archive.
--
-- An entry is `{ name = "in/the/archive", data = "bytes" }`, or `path` instead
-- of `data` for a file to read as it goes - which is what keeps packing a
-- folder from holding the whole folder in memory at once.
--
-- Streamed to the file rather than concatenated: an archive of a client's
-- tables is tens of megabytes, and building the whole of it as a Lua string
-- doubles that for no reason.
---@param target string
---@param entries table[] { name, data? , path?, level? }
---@param options? table { level? = integer }
---@return boolean|nil ok, string|nil err
M.write = (target, entries, options = {}) ->
  level = options.level or M.LEVEL
  library = compressor!

  folder = fs.dirname target
  if folder and folder != "" and not fs.is_dir folder
    made, make_err = fs.make_dir folder
    return nil, "cannot create #{folder}: #{tostring make_err}" unless made

  handle, open_err = io.open target, "wb"
  return nil, "cannot write #{target}: #{tostring open_err}" unless handle

  -- Reported rather than raised, and the half-written file removed with it:
  -- a truncated archive that looks like a backup is worse than no backup.
  fail = (message) ->
    handle\close!
    fs.remove target
    nil, message

  offset = 0
  directory = {}
  time, date = dos_stamp options.stamp

  for entry in *entries
    name = entry_name entry.name
    return fail "an entry needs a name" if name == ""

    data = entry.data
    unless data
      read, read_err = fs.read entry.path
      return fail "cannot read #{tostring entry.path}: #{tostring read_err}" unless read
      data = read

    return fail "#{name} is larger than a zip entry can be" if #data > LIMIT

    crc = M.crc32 data
    method = STORED
    payload = data

    if library and #data > 0
      squeezed = library\CompressDeflate data, { level: entry.level or level }

      -- Stored when compressing made it bigger, which happens with anything
      -- already compressed. The format allows both per entry, so there is no
      -- reason to write the worse one.
      if squeezed and #squeezed < #data
        method = DEFLATED
        payload = squeezed

    header = u32(LOCAL_SIG) .. u16(20) .. u16(0) .. u16(method) ..
      u16(time) .. u16(date) .. u32(crc) .. u32(#payload) .. u32(#data) ..
      u16(#name) .. u16(0) .. name

    written, write_err = handle\write header, payload
    return fail "cannot write #{target}: #{tostring write_err}" unless written

    table.insert directory, {
      :name, :method, :crc, :time, :date, :offset
      compressed: #payload
      size: #data
    }

    offset += #header + #payload
    return fail "#{target} would be larger than a zip can be" if offset > LIMIT

  start = offset

  for entry in *directory
    record = u32(CENTRAL_SIG) .. u16(20) .. u16(20) .. u16(0) ..
      u16(entry.method) .. u16(entry.time) .. u16(entry.date) ..
      u32(entry.crc) .. u32(entry.compressed) .. u32(entry.size) ..
      u16(#entry.name) .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(0) ..
      u32(entry.offset) .. entry.name

    written, write_err = handle\write record
    return fail "cannot write #{target}: #{tostring write_err}" unless written
    offset += #record

  tail = u32(END_SIG) .. u16(0) .. u16(0) .. u16(#directory) ..
    u16(#directory) .. u32(offset - start) .. u32(start) .. u16(0)

  written, write_err = handle\write tail
  return fail "cannot write #{target}: #{tostring write_err}" unless written

  handle\close!
  true

--- Packs everything under a folder.
--
-- Names are relative to the folder, so extracting the archive somewhere else
-- reproduces the folder rather than the machine it came from.
---@param target string
---@param folder string
---@param options? table Passed to `write`.
---@return integer|nil count, string|nil err
M.pack = (target, folder, options) ->
  return nil, "there is no folder at #{tostring folder}" unless fs.is_dir folder

  entries = {}
  for path in *(fs.walk folder) or {}
    table.insert entries, { name: (fs.relative path, folder), :path }

  -- A stable order, so the same folder packs to the same archive twice. The
  -- filesystem's order is not one.
  table.sort entries, (a, b) -> a.name < b.name

  ok, err = M.write target, entries, options
  return nil, err unless ok
  #entries, nil

-- ═══════════════════════════════════════════════════════════════════════════
-- Reading
-- ═══════════════════════════════════════════════════════════════════════════

--- Finds the end-of-directory record.
--
-- Searched for backwards rather than computed: the record sits at the end of
-- the file, but a comment of up to 64 KB may follow it, and a file written by
-- something else may have one.
---@param text string
---@return integer|nil at
---@private
end_record = (text) ->
  earliest = math.max 1, #text - 65557

  for at = #text - 21, earliest, -1
    return at if (number_at text, at, 4) == END_SIG
  nil

--- Reads the central directory.
---@param archive string Path to the archive.
---@return table[]|nil entries { name, size, compressed, method }
---@return string|nil err
M.entries = (archive) ->
  text, read_err = fs.read archive
  return nil, "cannot read #{archive}: #{tostring read_err}" unless text

  at = end_record text
  return nil, "#{archive} is not a zip archive" unless at

  count = number_at text, at + 10, 2
  start = number_at text, at + 16, 4

  entries = {}
  cursor = start + 1

  for _ = 1, count
    unless (number_at text, cursor, 4) == CENTRAL_SIG
      return nil, "#{archive} has a damaged directory"

    name_length = number_at text, cursor + 28, 2
    extra_length = number_at text, cursor + 30, 2
    comment_length = number_at text, cursor + 32, 2

    table.insert entries, {
      name: sub text, cursor + 46, cursor + 45 + name_length
      method: number_at text, cursor + 10, 2
      crc: number_at text, cursor + 16, 4
      compressed: number_at text, cursor + 20, 4
      size: number_at text, cursor + 24, 4
      offset: number_at text, cursor + 42, 4
    }

    cursor += 46 + name_length + extra_length + comment_length

  entries, nil

--- Reads one entry's bytes.
--
-- Here because a backup nobody can read back is a backup nobody can trust, and
-- because a suite that only checks an archive exists is checking nothing.
---@param archive string
---@param name string The name inside the archive.
---@return string|nil data, string|nil err
M.read = (archive, name) ->
  wanted = entry_name name

  listed, list_err = M.entries archive
  return nil, list_err unless listed

  found = nil
  for entry in *listed
    found = entry if entry.name == wanted

  return nil, "#{wanted} is not in #{archive}" unless found

  text = fs.read archive
  return nil, "cannot read #{archive}" unless text

  at = found.offset + 1
  unless (number_at text, at, 4) == LOCAL_SIG
    return nil, "#{wanted} is not where the directory says"

  -- The local header's own name and extra lengths, not the directory's: the
  -- extra field differs between the two by design, and using the wrong one
  -- lands a few bytes into the data.
  name_length = number_at text, at + 26, 2
  extra_length = number_at text, at + 28, 2

  starts = at + 30 + name_length + extra_length
  payload = sub text, starts, starts + found.compressed - 1

  return payload, nil if found.method == STORED

  unless found.method == DEFLATED
    return nil, "#{wanted} is compressed with method #{found.method}"

  library = compressor!
  unless library
    return nil, "#{wanted} is compressed and libdeflate is not installed"

  data, remaining = library\DecompressDeflate payload
  return nil, "#{wanted} could not be decompressed" unless data
  unless remaining == 0
    return nil, "#{wanted} has #{remaining} unexpected bytes after it"

  data, nil

M
