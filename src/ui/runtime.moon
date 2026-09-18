--- The reactive runtime that runs in the page.
--
-- Held here as source rather than as a file on disk, so it travels with the
-- compiled Lua and there is nothing to resolve, copy or fail to package.
-- `ui.document` inlines it; a page that wants it on its own can ask for
-- `runtime.tag!`.
--
-- What it provides, as `window.nui`:
--
--   nui.state           the store, as a proxy: read it, assign to it
--   nui.get/set(path)   the same, by dotted path
--   nui.signal/effect   the primitives underneath, for code that wants them
--   nui.bind(root)      wires the data- directives under a root
--   nui.html(el, html)  replaces content and wires what arrived
--   nui.run(source)     runs a statement with the store in scope
--   nui.evaluate(expr)  reads an expression with the store in scope
--
-- Reactivity is per top-level key. Writing `tree.nodes[3].open` re-runs every
-- effect that read `tree`. That is coarse, and for a tool's interface it is
-- also enough: the alternative is a proxy per node, and an order of magnitude
-- more of it to get wrong.
---@module ui.runtime

-- Level 2 brackets: the source below contains ]] in array expressions.
SOURCE = [==[
(() => {
  'use strict'
  if (window.nui) return

  // ── Signals ───────────────────────────────────────────────────────────────
  // The effect currently running, so a read can record who depends on it.
  let listener = null

  const queued = new Set()
  let scheduled = false

  // Effects run in a microtask rather than on the write, so setting three
  // fields in a row re-renders once instead of three times.
  const flush = () => {
    scheduled = false
    const runs = [...queued]
    queued.clear()
    for (const run of runs) run()
  }

  const schedule = (run) => {
    queued.add(run)
    if (scheduled) return
    scheduled = true
    queueMicrotask(flush)
  }

  const signal = (initial) => {
    let value = initial
    const subscribers = new Set()

    const read = () => {
      if (listener) subscribers.add(listener)
      return value
    }

    read.peek = () => value
    read.write = (next) => {
      if (Object.is(next, value)) return
      value = next
      // Copied, because an effect may subscribe again while we iterate.
      for (const run of [...subscribers]) schedule(run)
    }

    return read
  }

  const effect = (fn) => {
    const run = () => {
      const previous = listener
      listener = run
      try { fn() } finally { listener = previous }
    }
    run()
    return run
  }

  // ── The store ─────────────────────────────────────────────────────────────
  const cells = new Map()

  const cell = (key) => {
    let found = cells.get(key)
    if (!found) {
      found = signal(undefined)
      cells.set(key, found)
    }
    return found
  }

  // Set once the bridge is up; notifies Lua of a write made in the page.
  let onWrite = null

  const text = (value) => (value === undefined || value === null) ? '' : String(value)

  const get = (path) => {
    const parts = String(path).split('.')
    let node = cell(parts[0])()
    for (let i = 1; i < parts.length; i++) {
      if (node === undefined || node === null) return undefined
      node = node[parts[i]]
    }
    return node
  }

  const set = (path, value, push = true) => {
    const parts = String(path).split('.')

    if (parts.length === 1) {
      cell(parts[0]).write(value)
    } else {
      // Cloned rather than mutated: the signal compares with Object.is, and a
      // branch edited in place would be the same object it already held.
      const root = structuredClone(cell(parts[0]).peek() ?? {})
      let node = root
      for (let i = 1; i < parts.length - 1; i++) {
        if (node[parts[i]] === null || typeof node[parts[i]] !== 'object') node[parts[i]] = {}
        node = node[parts[i]]
      }
      node[parts[parts.length - 1]] = value
      cell(parts[0]).write(root)
    }

    if (push && onWrite) onWrite(String(path), value)
  }

  // Only declared keys are intercepted by `has`, so an expression in a
  // directive can still reach Math, JSON or anything else in scope. Keys are
  // declared from the state Lua inlined in the document.
  const state = new Proxy({}, {
    has: (_, key) => cells.has(key),
    get: (_, key) => cell(key)(),
    set: (_, key, value) => { set(key, value); return true },
    deleteProperty: (_, key) => { set(key, undefined); return true },
    ownKeys: () => [...cells.keys()],
    getOwnPropertyDescriptor: () => ({ enumerable: true, configurable: true })
  })

  const declare = (values) => {
    for (const key of Object.keys(values ?? {})) cell(key).write(values[key])
  }

  // ── Scopes ────────────────────────────────────────────────────────────────
  // A row inside data-for needs its own names without putting them in the
  // store. `has` answers for own keys only, so anything else falls through to
  // the store and then to normal scope.
  const scoped = (values) => new Proxy(values, {
    has: (target, key) => Object.prototype.hasOwnProperty.call(target, key),
    get: (target, key) => target[key]
  })


  // ── Directives ────────────────────────────────────────────────────────────
  // Compiled with `with`, which is why these are built through new Function:
  // a function body made that way is not strict, and this file is. The scope is
  // the inner `with`, so a row's own names win over the store's.
  const expression = (source) =>
    new Function('$state', '$scope', '$el', '$event',
      `with ($state) { with ($scope) { return (${source}) } }`)

  const statement = (source) =>
    new Function('$state', '$scope', '$el', '$event',
      `with ($state) { with ($scope) { ${source} } }`)

  const bound = new WeakSet()

  // Turns a leftover <template shadowrootmode> into a real shadow root.
  //
  // Chromium's parser normally does this itself, including inside another
  // template's content, so this finds nothing most of the time. It matters for
  // markup that never went through the parser that way - innerHTML on a browser
  // without setHTMLUnsafe, or a fragment assembled by hand. Cheap, and the
  // failure it prevents is silent: a widget with no styles and no slots.
  const hydrate = (root) => {
    for (const template of root.querySelectorAll('template[shadowrootmode]')) {
      const host = template.parentNode
      if (!host || host.shadowRoot) continue

      const mode = template.getAttribute('shadowrootmode')
      const shadow = host.attachShadow({ mode: mode === 'closed' ? 'closed' : 'open' })
      shadow.appendChild(template.content)
      template.remove()

      // querySelectorAll does not cross a shadow boundary, so the widgets
      // nested inside this one need their own pass.
      hydrate(shadow)
    }
    return root
  }

  // Parses declarative shadow roots, which innerHTML silently drops: a widget
  // assigned that way would lose its styles and its slots with no error.
  const setHTML = (el, markup) => {
    if (el.setHTMLUnsafe) el.setHTMLUnsafe(markup)
    else el.innerHTML = markup
    hydrate(el)
  }

  const bindModel = (el, path) => {
    const checkbox = el.type === 'checkbox'

    effect(() => {
      const value = get(path)
      if (checkbox) el.checked = !!value
      else if (el.value !== text(value)) el.value = text(value)
    })

    el.addEventListener('input', () => set(path, checkbox ? el.checked : el.value))
  }

  const FOR = /^\s*([A-Za-z_$][\w$]*)\s*(?:,\s*([A-Za-z_$][\w$]*)\s*)?\bin\b([\s\S]+)$/

  // Rebuilds its rows wholesale whenever the list changes. That matches the
  // store's own granularity - a write anywhere under `files` invalidates
  // `files` - and a tool's list is tens of rows, not thousands.
  const bindFor = (el, source, outer) => {
    const match = FOR.exec(source)
    if (!match) { console.error('[neutrino] data-for expects "item in list":', source); return }

    const itemName = match[1]
    const indexName = match[2]
    const template = el.querySelector(':scope > template')
    if (!template) { console.error('[neutrino] data-for needs a <template> child'); return }

    const read = expression(match[3])

    effect(() => {
      const items = read(state, scoped(outer ?? {}), el)
      const list = Array.isArray(items) ? items : []

      for (const child of [...el.children]) {
        if (child !== template) child.remove()
      }

      list.forEach((item, index) => {
        const values = Object.assign({}, outer)
        values[itemName] = item
        if (indexName) values[indexName] = index

        const fragment = template.content.cloneNode(true)
        const roots = [...fragment.children]
        el.appendChild(fragment)

        // Hydrated before binding, so bindTree finds the shadow roots to
        // descend into rather than a pile of inert templates.
        for (const root of roots) bindTree(hydrate(root), values)
      })
    })
  }

  const bindElement = (el, outer) => {
    if (bound.has(el)) return
    bound.add(el)

    const scope = scoped(outer ?? {})

    for (const attribute of [...el.attributes]) {
      if (!attribute.name.startsWith('data-')) continue

      const name = attribute.name.slice(5)
      const source = attribute.value

      if (name === 'text') {
        const read = expression(source)
        effect(() => { el.textContent = text(read(state, scope, el)) })
      } else if (name === 'html') {
        const read = expression(source)
        effect(() => {
          setHTML(el, text(read(state, scope, el)))
          // Whatever just arrived has directives of its own.
          bindTree(el, outer)
        })
      } else if (name === 'show') {
        const read = expression(source)
        effect(() => { el.hidden = !read(state, scope, el) })
      } else if (name === 'for') {
        bindFor(el, source, outer)
      } else if (name === 'model') {
        bindModel(el, source)
      } else if (name.startsWith('attr-')) {
        const attributeName = name.slice(5)
        const read = expression(source)
        effect(() => {
          const value = read(state, scope, el)
          if (value === false || value === undefined || value === null) el.removeAttribute(attributeName)
          else el.setAttribute(attributeName, value === true ? '' : String(value))
        })
      } else if (name.startsWith('class-')) {
        const className = name.slice(6)
        const read = expression(source)
        effect(() => { el.classList.toggle(className, !!read(state, scope, el)) })
      } else if (name.startsWith('on-')) {
        const run = statement(source)
        el.addEventListener(name.slice(3), (event) => run(state, scope, el, event))
      }
    }
  }

  // Descends into shadow roots, because that is where a widget's markup lives
  // and it would otherwise never be wired. A <template> is skipped: its content
  // is inert, and data-for binds the clones instead.
  const bindTree = (root, outer) => {
    const node = root ?? document
    if (node.nodeType === Node.ELEMENT_NODE) {
      if (node.tagName === 'TEMPLATE') return node
      bindElement(node, outer)
      // The root's own shadow root too: querySelectorAll never returns the node
      // it was called on, so a widget handed here directly - which is every row
      // data-for builds - would keep its markup unwired.
      if (node.shadowRoot) bindTree(node.shadowRoot, outer)
    }

    for (const el of node.querySelectorAll('*')) {
      if (el.closest('template')) continue
      if (el.attributes.length) bindElement(el, outer)
      if (el.shadowRoot) bindTree(el.shadowRoot, outer)
    }

    return node
  }

  const bind = (root) => bindTree(root, null)

  // ── The bridge to Lua ─────────────────────────────────────────────────────
  const connect = () => {
    if (!window.neutrino) return

    onWrite = (path, value) => window.neutrino.invoke('ui:state', { path, value })

    // Applied without pushing back, or Lua's own write would return to it.
    window.neutrino.on('ui:state', (payload) => {
      if (payload && typeof payload.path === 'string') set(payload.path, payload.value, false)
    })
  }

  window.nui = {
    signal, effect, state, get, bind, declare,
    set: (path, value) => set(path, value, true),
    apply: (path, value) => set(path, value, false),

    // Replaces an element's content with markup from a route and wires it.
    // The parse goes through setHTMLUnsafe so a widget keeps its shadow root.
    html: (el, markup) => { setHTML(el, markup); bind(el); return el },

    // The evaluation a directive gets, for code that is not attached to an
    // element. A keyboard shortcut can then run exactly what its menu entry
    // runs, instead of the same intent written twice in two dialects.
    run: (source, scope) => statement(source)(state, scoped(scope ?? {})),
    evaluate: (source, scope) => expression(source)(state, scoped(scope ?? {}))
  }

  const boot = () => {
    declare(window.__NEUTRINO_STATE__)
    connect()
    bind(document)
    if (window.neutrino) window.neutrino.invoke('ui:ready', {})
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot)
  else boot()
})()
]==]

--- The runtime source, without a script tag.
---@return string
source = -> SOURCE

--- The runtime wrapped in a script tag, ready to drop into a document head.
---@return string
tag = -> "<script>" .. SOURCE .. "</script>"

{ :source, :tag }
