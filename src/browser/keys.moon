--- Keyboard accelerators.
--
-- Turns a description such as "Ctrl+Shift+I" into something that can be matched
-- against the key events CEF reports, so an application can claim a shortcut
-- without knowing Windows virtual key codes.
---@module browser.keys

M = {}

--- Virtual key codes, by the name used in an accelerator string.
-- Only the keys an accelerator plausibly uses; letters and digits are derived.
NAMED_KEYS = {
  backspace: 0x08, tab: 0x09, enter: 0x0D, ["return"]: 0x0D
  escape: 0x1B, esc: 0x1B, space: 0x20
  pageup: 0x21, pagedown: 0x22, ["end"]: 0x23, home: 0x24
  left: 0x25, up: 0x26, right: 0x27, down: 0x28
  insert: 0x2D, delete: 0x2E, del: 0x2E
  plus: 0xBB, minus: 0xBD, comma: 0xBC, period: 0xBE
}
for index = 1, 24
  NAMED_KEYS["f#{index}"] = 0x6F + index

M.NAMED_KEYS = NAMED_KEYS

--- The punctuation keys, by the character itself.
--
-- "Ctrl+," is what almost every editor calls its settings shortcut, and a menu
-- that had to advertise it as "Ctrl+Comma" would be advertising something
-- nobody types. The named spellings above still work; these are the same keys
-- written the way they are printed.
--
-- "+" is absent and stays absent: the accelerator is split on it, so the key
-- has to be reached as "Plus".
PUNCTUATION = {
  [","]: 0xBC, ["."]: 0xBE, ["-"]: 0xBD, ["="]: 0xBB
  [";"]: 0xBA, ["/"]: 0xBF, ["\\"]: 0xDC, ["'"]: 0xDE
  ["["]: 0xDB, ["]"]: 0xDD, ["`"]: 0xC0
}

M.PUNCTUATION = PUNCTUATION

--- Parses an accelerator into the parts a key event is matched on.
---@param accelerator string For example "Ctrl+Shift+I", "F12", "Alt+Left".
---@return table|nil spec { key_code, ctrl, shift, alt, meta }, or nil and an error.
M.parse = (accelerator) ->
  return nil, "accelerator must be a string" unless type(accelerator) == "string"

  spec = { key_code: nil, ctrl: false, shift: false, alt: false, meta: false }

  for part in accelerator\gmatch "[^+]+"
    token = part\match("^%s*(.-)%s*$")\lower!
    continue if token == ""

    switch token
      when "ctrl", "control" then spec.ctrl = true
      when "shift" then spec.shift = true
      when "alt" then spec.alt = true
      when "meta", "super", "win", "cmd" then spec.meta = true
      else
        return nil, "accelerator '#{accelerator}' names more than one key" if spec.key_code

        if #token == 1
          byte = token\upper!\byte 1
          -- Letters and digits share their ASCII value as a virtual key code.
          if (byte >= 65 and byte <= 90) or (byte >= 48 and byte <= 57)
            spec.key_code = byte
          elseif PUNCTUATION[token]
            spec.key_code = PUNCTUATION[token]
          else
            return nil, "unrecognised key '#{token}' in '#{accelerator}'"
        else
          code = NAMED_KEYS[token]
          return nil, "unrecognised key '#{token}' in '#{accelerator}'" unless code
          spec.key_code = code

  return nil, "accelerator '#{accelerator}' names no key" unless spec.key_code
  spec

--- Reports whether a key event matches a parsed accelerator.
-- Matches on keydown only: a shortcut that also fired on keyup would run twice.
---@param spec table From M.parse.
---@param event table The key event reported by the window.
---@return boolean
M.matches = (spec, event) ->
  return false unless event.type == "rawkeydown" or event.type == "keydown"
  return false unless event.keyCode == spec.key_code

  event.ctrl == spec.ctrl and
    event.shift == spec.shift and
    event.alt == spec.alt and
    event.meta == spec.meta

M
