class Post
  toString: -> @ID

  constructor: (root, @thread, @board) ->
    <% if (readJSON('/.tests_enabled')) { %>
    @normalizedOriginal = Build.Test.normalize root
    <% } %>

    @ID       = +root.id[2..]
    @threadID = @thread.ID
    @boardID  = @board.ID
    @fullID   = "#{@board}.#{@ID}"
    @context  = @

    root.dataset.fullID = @fullID

    @nodes = @parseNodes root

    if not (@isReply = $.hasClass @nodes.post, 'reply')
      @thread.OP = @
      if @boardID is 'f'
        for type in ['Sticky', 'Closed'] when (icon = $ "img[alt=#{type}]", @nodes.info)
          $.addClass icon, "#{type.toLowerCase()}Icon", 'retina'
      @thread.isArchived = !!$ '.archivedIcon', @nodes.info
      @thread.isSticky   = !!$ '.stickyIcon', @nodes.info
      @thread.isClosed   = @thread.isArchived or !!$ '.closedIcon', @nodes.info
      @thread.kill() if @thread.isArchived

    @info =
      subject:   @nodes.subject?.textContent or undefined
      name:      @nodes.name?.textContent
      tripcode:  @nodes.tripcode?.textContent
      uniqueID:  @nodes.uniqueID?.textContent
      capcode:   @nodes.capcode?.textContent.replace '## ', ''
      pass:      @nodes.pass?.title.match(/\d*$/)[0]
      flagCode:  @nodes.flag?.className.match(/flag-(\w+)/)?[1].toUpperCase()
      flagCodeTroll: @nodes.flag?.src?.match(/(\w+)\.gif$/)?[1].toUpperCase()
      flag:      @nodes.flag?.title
      date:      if @nodes.date then new Date(@nodes.date.dataset.utc * 1000)

    if Conf['Anonymize']
      @info.nameBlock = 'Anonymous'
    else
      @info.nameBlock = "#{@info.name or ''} #{@info.tripcode or ''}".trim()
    @info.nameBlock += " ## #{@info.capcode}"     if @info.capcode
    @info.nameBlock += " (ID: #{@info.uniqueID})" if @info.uniqueID

    @parseComment()
    @parseQuotes()
    @parseFile()

    @isDead   = false
    @isHidden = false

    @clones = []
    <% if (readJSON('/.tests_enabled')) { %>
    return if arguments[3] is 'forBuildTest'
    <% } %>
    if g.posts[@fullID]
      @isRebuilt = true
      @clones = g.posts[@fullID].clones
      clone.origin = @ for clone in @clones

    @board.posts.push  @ID, @
    @thread.posts.push @ID, @
    g.posts.push   @fullID, @

  parseNodes: (root) ->
    post = $ '.post',     root
    info = $ '.postInfo', post
    nodes =
      root:         root
      post:         post
      info:         info
      subject:      $ '.subject',            info
      name:         $ '.name',               info
      email:        $ '.useremail',          info
      tripcode:     $ '.postertrip',         info
      uniqueIDRoot: $ '.posteruid',          info
      uniqueID:     $ '.posteruid > .hand',  info
      capcode:      $ '.capcode.hand',       info
      pass:         $ '.n-pu',               info
      flag:         $ '.flag, .countryFlag', info
      date:         $ '.dateTime',           info
      nameBlock:    $ '.nameBlock',          info
      quote:        $ '.postNum > a:nth-of-type(2)', info
      reply:        $ '.replylink',          info
      fileRoot:     $ '.file',        post
      comment:      $ '.postMessage', post
      quotelinks:   []
      archivelinks: []
      embedlinks:   []

    # XXX Edge invalidates HTMLCollections when an ancestor node is inserted into another node.
    # https://developer.microsoft.com/en-us/microsoft-edge/platform/issues/7560353/
    if $.engine is 'edge'
      Object.defineProperty nodes, 'backlinks',
        configurable: true
        enumerable:   true
        get: -> post.getElementsByClassName 'backlink'
    else
      nodes.backlinks = post.getElementsByClassName 'backlink'

    nodes

  parseComment: ->
    # Merge text nodes and remove empty ones.
    @nodes.comment.normalize()

    # Get the comment's text.
    # <br> -> \n
    # Remove:
    #   'Comment too long'...
    #   EXIF data. (/p/)
    @nodes.commentClean = bq = @nodes.comment.cloneNode true
    @cleanComment bq
    @info.comment = @nodesToText bq

  commentDisplay: ->
    # Get the comment's text for display purposes (e.g. notifications, excerpts).
    # In addition to what's done in generating `@info.comment`, remove:
    #   Spoilers. (filter to '[spoiler]')
    #   Rolls. (/tg/, /qst/)
    #   Fortunes. (/s4s/)
    #   Preceding and following new lines.
    #   Trailing spaces.
    bq = @nodes.commentClean.cloneNode true
    @cleanSpoilers bq unless Conf['Remove Spoilers'] or Conf['Reveal Spoilers']
    @cleanCommentDisplay bq
    @nodesToText(bq).trim().replace(/\s+$/gm, '')

  commentOrig: ->
    # Get the comment's text for reposting purposes.
    bq = @nodes.commentClean.cloneNode true
    @insertTags bq
    @nodesToText bq

  nodesToText: (bq) ->
    text = ""
    nodes = $.X './/br|.//text()', bq
    i = 0
    while node = nodes.snapshotItem i++
      text += node.data or '\n'
    text

  cleanComment: (bq) ->
    if (abbr = $ '.abbr', bq) # 'Comment too long' or 'EXIF data available'
      for node in $$ '.abbr + br, .exif', bq
        $.rm node
      for i in [0...2]
        $.rm br if (br = abbr.previousSibling) and br.nodeName is 'BR'
      $.rm abbr

  cleanSpoilers: (bq) ->
    spoilers = $$ 's', bq
    for node in spoilers
      $.replace node, $.tn '[spoiler]'
    return

  cleanCommentDisplay: (bq) ->
    $.rm b if (b = $ 'b', bq) and /^Rolled /.test(b.textContent)
    $.rm $('.fortune', bq)

  insertTags: (bq) ->
    for node in $$ 's, .removed-spoiler', bq
      $.replace node, [$.tn('[spoiler]'), node.childNodes..., $.tn '[/spoiler]']
    for node in $$ '.prettyprint', bq
      $.replace node, [$.tn('[code]'), node.childNodes..., $.tn '[/code]']
    return

  parseQuotes: ->
    @quotes = []
    # XXX https://github.com/4chan/4chan-JS/issues/77
    # 4chan currently creates quote links inside [code] tags; ignore them
    for quotelink in $$ ':not(pre) > .quotelink', @nodes.comment
      @parseQuote quotelink
    return

  parseQuote: (quotelink) ->
    # Only add quotes that link to posts on an imageboard.
    # Don't add:
    #  - board links. (>>>/b/)
    #  - catalog links. (>>>/b/catalog or >>>/b/search)
    #  - rules links. (>>>/a/rules)
    #  - text-board quotelinks. (>>>/img/1234)
    match = quotelink.href.match ///
      ^https?://boards\.4chan\.org/+
      ([^/]+) # boardID
      /+(?:res|thread)/+\d+(?:[/?][^#]*)?#p
      (\d+)   # postID
      $
    ///
    return unless match or (@isClone and quotelink.dataset.postID) # normal or resurrected quote

    @nodes.quotelinks.push quotelink

    return if @isClone

    # ES6 Set when?
    fullID = "#{match[1]}.#{match[2]}"
    @quotes.push fullID unless fullID in @quotes

  parseFile: ->
    {fileRoot} = @nodes
    return unless fileRoot
    return if not (link = $ '.fileText > a, .fileText-original > a', fileRoot)
    return if not (info = link.nextSibling?.textContent.match /\(([\d.]+ [KMG]?B).*\)/)
    fileText = fileRoot.firstElementChild
    @file =
      text:       fileText
      link:       link
      url:        link.href
      name:       fileText.title or link.title or link.textContent
      size:       info[1]
      isImage:    /(jpg|png|gif)$/i.test link.href
      isVideo:    /webm$/i.test link.href
      dimensions: info[0].match(/\d+x\d+/)?[0]
      tag:        info[0].match(/,[^,]*, ([a-z]+)\)/i)?[1]
      MD5:        fileText.dataset.md5
    size  = +@file.size.match(/[\d.]+/)[0]
    unit  = ['B', 'KB', 'MB', 'GB'].indexOf @file.size.match(/\w+$/)[0]
    size *= 1024 while unit-- > 0
    @file.sizeInBytes = size
    if (thumb = $ 'a.fileThumb > [data-md5]', fileRoot)
      $.extend @file,
        thumb:     thumb
        thumbLink: thumb.parentNode
        thumbURL:  thumb.src
        MD5:       thumb.dataset.md5
        isSpoiler: $.hasClass thumb.parentNode, 'imgspoiler'
      if @file.isSpoiler
        @file.thumbURL = if (m = link.href.match /\d+(?=\.\w+$)/) then "#{location.protocol}//#{ImageHost.thumbHost()}/#{@board}/#{m[0]}s.jpg"

  @deadMark =
    # \u00A0 is nbsp
    $.el 'span',
      textContent: '\u00A0(Dead)'
      className:   'qmark-dead'

  kill: (file) ->
    if file
      return if @isDead or @file.isDead
      @file.isDead = true
      $.addClass @nodes.root, 'deleted-file'
    else
      return if @isDead
      @isDead = true
      $.rmClass  @nodes.root, 'deleted-file'
      $.addClass @nodes.root, 'deleted-post'

    if not (strong = $ 'strong.warning', @nodes.info)
      strong = $.el 'strong',
        className: 'warning'
      $.after $('input', @nodes.info), strong
    strong.textContent = if file then '[File deleted]' else '[Deleted]'

    return if @isClone
    for clone in @clones
      clone.kill file

    return if file
    # Get quotelinks/backlinks to this post
    # and paint them (Dead).
    for quotelink in Get.allQuotelinksLinkingTo @ when not $.hasClass quotelink, 'deadlink'
      $.add quotelink, Post.deadMark.cloneNode(true)
      $.addClass quotelink, 'deadlink'
    return

  # XXX Workaround for 4chan's racing condition
  # giving us false-positive dead posts.
  resurrect: ->
    @isDead = false
    $.rmClass @nodes.root, 'deleted-post'
    strong = $ 'strong.warning', @nodes.info
    # no false-positive files
    if @file and @file.isDead
      strong.textContent = '[File deleted]'
    else
      $.rm strong

    return if @isClone
    for clone in @clones
      clone.resurrect()

    for quotelink in Get.allQuotelinksLinkingTo @ when $.hasClass quotelink, 'deadlink'
      $.rm $('.qmark-dead', quotelink)
      $.rmClass quotelink, 'deadlink'
    return

  collect: ->
    g.posts.rm @fullID
    @thread.posts.rm @
    @board.posts.rm @

  addClone: (context, contractThumb) ->
    # Callbacks may not have been run yet due to anti-browser-lock delay in Main.callbackNodesDB.
    Callbacks.Post.execute @
    new Post.Clone @, context, contractThumb

  rmClone: (index) ->
    @clones.splice index, 1
    for clone in @clones[index..]
      clone.nodes.root.dataset.clone = index++
    return

  setCatalogOP: (isCatalogOP) ->
    @nodes.root.classList.toggle 'catalog-container', isCatalogOP
    @nodes.root.classList.toggle 'opContainer', !isCatalogOP
    @nodes.post.classList.toggle 'catalog-post', isCatalogOP
    @nodes.post.classList.toggle 'op', !isCatalogOP
    @nodes.post.style.left = @nodes.post.style.right = null
