sax = require 'sax'
events = require 'events'
builder = require 'xmlbuilder'
bom = require './bom'
processors = require './processors'

# Underscore has a nice function for this, but we try to go without dependencies
isEmpty = (thing) ->
  return typeof thing is "object" && thing? && Object.keys(thing).length is 0

processName = (processors, processedName) ->
  processedName = process(processedName) for process in processors
  return processedName

requiresCDATA = (entry) ->
  return entry.indexOf('&') >= 0 || entry.indexOf('>') >= 0 || entry.indexOf('<') >= 0

# Note that we do this manually instead of using xmlbuilder's `.dat` method
# since it does not support escaping the CDATA close entity (throws an error if
# it exists, and if it's pre-escaped).
wrapCDATA = (entry) ->
  return "<![CDATA[#{escapeCDATA entry}]]>"

escapeCDATA = (entry) ->
  # Split the CDATA section in two;
  # The first contains the ']]'
  # The second contains the '>'
  # When later parsed, it will be put back together as ']]>'
  return entry.replace ']]>', ']]]]><![CDATA[>'

exports.processors = processors

exports.defaults =
  "0.1":
    explicitCharkey: false
    trim: true
    # normalize implicates trimming, just so you know
    normalize: true
    # normalize tag names to lower case
    normalizeTags: false
    # set default attribute object key
    attrkey: "@"
    # set default char object key
    charkey: "#"
    # always put child nodes in an array
    explicitArray: false
    # ignore all attributes regardless
    ignoreAttrs: false
    # merge attributes and child elements onto parent object.  this may
    # cause collisions.
    mergeAttrs: false
    explicitRoot: false
    validator: null
    xmlns : false
    # fold children elements into dedicated property (works only in 0.2)
    explicitChildren: false
    childkey: '@@'
    charsAsChildren: false
    # callbacks are async? not in 0.1 mode
    async: false
    strict: true
    attrNameProcessors: null
    tagNameProcessors: null
    valueProcessors: null
    emptyTag: ''

  "0.2":
    explicitCharkey: false
    trim: false
    normalize: false
    normalizeTags: false
    attrkey: "$"
    charkey: "_"
    explicitArray: true
    ignoreAttrs: false
    mergeAttrs: false
    explicitRoot: true
    validator: null
    xmlns : false
    explicitChildren: false
    childkey: '$$'
    charsAsChildren: false
    # not async in 0.2 mode either
    async: false
    strict: true
    attrNameProcessors: null
    tagNameProcessors: null
    valueProcessors: null
    # xml building options
    rootName: 'root'
    xmldec: {'version': '1.0', 'encoding': 'UTF-8', 'standalone': true}
    doctype: null
    renderOpts: { 'pretty': true, 'indent': '  ', 'newline': '\n' }
    headless: false
    chunkSize: 10000
    emptyTag: ''
    cdata: false

class exports.ValidationError extends Error
  constructor: (message) ->
    @message = message

class exports.Builder
  constructor: (opts) ->
    # copy this versions default options
    @options = {}
    @options[key] = value for own key, value of exports.defaults["0.2"]
    # overwrite them with the specified options, if any
    @options[key] = value for own key, value of opts

  buildObject: (rootObj) ->
    attrkey = @options.attrkey
    charkey = @options.charkey

    # If there is a sane-looking first element to use as the root,
    # and the user hasn't specified a non-default rootName,
    if ( Object.keys(rootObj).length is 1 ) and ( @options.rootName == exports.defaults['0.2'].rootName )
      # we'll take the first element as the root element
      rootName = Object.keys(rootObj)[0]
      rootObj = rootObj[rootName]
    else
      # otherwise we'll use whatever they've set, or the default
      rootName = @options.rootName

    render = (element, obj) =>
      if typeof obj isnt 'object'
        # single element, just append it as text
        if @options.cdata && requiresCDATA obj
          element.raw wrapCDATA obj
        else
          element.txt obj
      else
        for own key, child of obj
          # Case #1 Attribute
          if key is attrkey
            if typeof child is "object"
              # Inserts tag attributes
              for attr, value of child
                element = element.att(attr, value)

          # Case #2 Char data (CDATA, etc.)
          else if key is charkey
            if @options.cdata && requiresCDATA child
              element = element.raw wrapCDATA child
            else
              element = element.txt child

          # Case #3 Array data
          else if Array.isArray child
            for own index, entry of child
              if typeof entry is 'string'
                if @options.cdata && requiresCDATA entry
                  element = element.ele(key).raw(wrapCDATA entry).up()
                else
                  element = element.ele(key, entry).up()
              else
                element = arguments.callee(element.ele(key), entry).up()

          # Case #4 Objects
          else if typeof child is "object"
            element = arguments.callee(element.ele(key), child).up()

          # Case #5 String and remaining types
          else
            element = element.ele(key, child.toString()).up()

      element

    rootElement = builder.create(rootName, @options.xmldec, @options.doctype,
      headless: @options.headless)

    render(rootElement, rootObj).end(@options.renderOpts)

class exports.Parser extends events.EventEmitter
  constructor: (opts) ->
    # if this was called without 'new', create an instance with new and return
    return new exports.Parser opts unless @ instanceof exports.Parser
    # copy this versions default options
    @options = {}
    @options[key] = value for own key, value of exports.defaults["0.2"]
    # overwrite them with the specified options, if any
    @options[key] = value for own key, value of opts
    # define the key used for namespaces
    if @options.xmlns
      @options.xmlnskey = @options.attrkey + "ns"
    if @options.normalizeTags
      if ! @options.tagNameProcessors
        @options.tagNameProcessors = []
      @options.tagNameProcessors.unshift processors.normalize

    @reset()

  processAsync: =>
    if @remaining.length <= @options.chunkSize
      chunk = @remaining
      @remaining = ''
      @saxParser = @saxParser.write chunk
      @saxParser.close()
    else
      chunk = @remaining.substr 0, @options.chunkSize
      @remaining = @remaining.substr @options.chunkSize, @remaining.length
      @saxParser = @saxParser.write chunk
      setImmediate @processAsync

  assignOrPush: (obj, key, newValue) =>
    if key not of obj
      if not @options.explicitArray
        obj[key] = newValue
      else
        obj[key] = [newValue]
    else
      obj[key] = [obj[key]] if not (obj[key] instanceof Array)
      obj[key].push newValue

  reset: =>
    # remove all previous listeners for events, to prevent event listener
    # accumulation
    @removeAllListeners()
    # make the SAX parser. tried trim and normalize, but they are not
    # very helpful
    @saxParser = sax.parser @options.strict, {
      trim: false,
      normalize: false,
      xmlns: @options.xmlns
    }

    # emit one error event if the sax parser fails. this is mostly a hack, but
    # the sax parser isn't state of the art either.
    @saxParser.errThrown = false
    @saxParser.onerror = (error) =>
      @saxParser.resume()
      if ! @saxParser.errThrown
        @saxParser.errThrown = true
        @emit "error", error

    # another hack to avoid throwing exceptions when the parsing has ended
    # but the user-supplied callback throws an error
    @saxParser.ended = false

    # always use the '#' key, even if there are no subkeys
    # setting this property by and is deprecated, yet still supported.
    # better pass it as explicitCharkey option to the constructor
    @EXPLICIT_CHARKEY = @options.explicitCharkey
    @resultObject = null
    stack = []
    # aliases, so we don't have to type so much
    attrkey = @options.attrkey
    charkey = @options.charkey

    @saxParser.onopentag = (node) =>
      obj = {}
      obj[charkey] = ""
      unless @options.ignoreAttrs
        for own key of node.attributes
          if attrkey not of obj and not @options.mergeAttrs
            obj[attrkey] = {}
          newValue = node.attributes[key]
          processedKey = if @options.attrNameProcessors then processName(@options.attrNameProcessors, key) else key
          if @options.mergeAttrs
            @assignOrPush obj, processedKey, newValue
          else
            obj[attrkey][processedKey] = newValue

      # need a place to store the node name
      obj["#name"] = if @options.tagNameProcessors then processName(@options.tagNameProcessors, node.name) else node.name
      if (@options.xmlns)
        obj[@options.xmlnskey] = {uri: node.uri, local: node.local}
      stack.push obj

    @saxParser.onclosetag = =>
      obj = stack.pop()
      nodeName = obj["#name"]
      delete obj["#name"]

      cdata = obj.cdata
      delete obj.cdata

      s = stack[stack.length - 1]
      # remove the '#' key altogether if it's blank
      if obj[charkey].match(/^\s*$/) and not cdata
        emptyStr = obj[charkey]
        delete obj[charkey]
      else
        obj[charkey] = obj[charkey].trim() if @options.trim
        obj[charkey] = obj[charkey].replace(/\s{2,}/g, " ").trim() if @options.normalize
        obj[charkey] = if @options.valueProcessors then processName @options.valueProcessors, obj[charkey] else obj[charkey]
        # also do away with '#' key altogether, if there's no subkeys
        # unless EXPLICIT_CHARKEY is set
        if Object.keys(obj).length == 1 and charkey of obj and not @EXPLICIT_CHARKEY
          obj = obj[charkey]

      if (isEmpty obj)
        obj = if @options.emptyTag != '' then @options.emptyTag else emptyStr

      if @options.validator?
        xpath = "/" + (node["#name"] for node in stack).concat(nodeName).join("/")
        try
          obj = @options.validator(xpath, s and s[nodeName], obj)
        catch err
          @emit "error", err

      # put children into <childkey> property and unfold chars if necessary
      if @options.explicitChildren and not @options.mergeAttrs and typeof obj is 'object'
        node = {}
        # separate attributes
        if @options.attrkey of obj
          node[@options.attrkey] = obj[@options.attrkey]
          delete obj[@options.attrkey]
        # separate char data
        if not @options.charsAsChildren and @options.charkey of obj
          node[@options.charkey] = obj[@options.charkey]
          delete obj[@options.charkey]

        if Object.getOwnPropertyNames(obj).length > 0
          node[@options.childkey] = obj

        obj = node

      # check whether we closed all the open tags
      if stack.length > 0
        @assignOrPush s, nodeName, obj
      else
        # if explicitRoot was specified, wrap stuff in the root tag name
        if @options.explicitRoot
          # avoid circular references
          old = obj
          obj = {}
          obj[nodeName] = old

        @resultObject = obj
        # parsing has ended, mark that so we won't throw exceptions from
        # here anymore
        @saxParser.ended = true
        @emit "end", @resultObject

    ontext = (text) =>
      s = stack[stack.length - 1]
      if s
        s[charkey] += text
        s

    @saxParser.ontext = ontext
    @saxParser.oncdata = (text) =>
      s = ontext text
      if s
        s.cdata = true

  parseString: (str, cb) =>
    if cb? and typeof cb is "function"
      @on "end", (result) ->
        @reset()
        cb null, result
      @on "error", (err) ->
        @reset()
        cb err

    str = str.toString()
    if str.trim() is ''
      @emit "end", null
      return true

    try
      str = bom.stripBOM str
      if @options.async
        @remaining = str
        setImmediate @processAsync
        @saxParser
      @saxParser.write(str).close()
    catch err
      unless @saxParser.errThrown or @saxParser.ended
        @emit 'error', err
        @saxParser.errThrown = true
      else if @saxParser.ended
        throw err

exports.parseString = (str, a, b) ->
  # let's determine what we got as arguments
  if b?
    if typeof b == 'function'
      cb = b
    if typeof a == 'object'
      options = a
  else
    # well, b is not set, so a has to be a callback
    if typeof a == 'function'
      cb = a
    # and options should be empty - default
    options = {}

  # the rest is super-easy
  parser = new exports.Parser options
  parser.parseString str, cb
