client         = require './client'
fs             = require 'fs'
{exists}       = require 'path'
{pause}        = require './util'
{spawn, exec}  = require 'child_process'
{EventEmitter} = require 'events'

# **Process** manages a single Ruby worker process.
#
# A Process requires a path to a rackup config file _(config.ru)_.
#
#     process.createProcess("/path/to/app/config.ru");
#
# You can set a idle time so the process dies after a
# specified amount of milliseconds.
#
#     var ms = 15 * 60 * 1000;
#     process.createProcess("/path/to/app/config.ru", { idle: ms });
#
# A Process has 5 states:
#
# > `null`: Not started or dead
# >
# > `spawning`: Is booting and can't accept a connection yet
# >
# > `ready`: Is ready to accept a connection and handle a request
# >
# > `busy`: Is currently handling a request, not ready
# >
# > `quitting`: Was set a kill signal and is shutting down
#
# Anytime a process changes states, an event is fired with the new
# state name. When the process becomes `ready`, a `ready` is fired.
#
# Other events:
#
# > **Event: 'error'**
# >
# > `function (exception) { }`
# >
# > Emitted when an error occurs.
# >
# > **Event: 'spawn'**
# >
# > `function (exception) { }`
# >
# > Emitted when the process moves from `spawning` to `ready` state.
# >
# > **Event: 'exit'**
# >
# > `function () { }`
# >
# > Emitted when the Process terminates.
# >
# > **Event: 'idle'**
# >
# > `function () { }`
# >
# > Emitted when the Process times out because of inactivity.
#
exports.Process = class Process extends EventEmitter
  constructor: (@config, options) ->
    options ?= {}
    @idle  = options.idle
    @cwd   = options.cwd
    @debug = options.debug

    # Set initial state to `null`
    @state = null

    raiseConfigError = =>
      @emit 'error', new Error "configuration \"#{@config}\" doesn't exist"

    # Raise an exception unless `config` exists
    if @config?
      exists @config, (ok) =>
        raiseConfigError() if !ok
    else
      raiseConfigError()

    # Push back the idle time everytime a request is handled
    @on 'busy', =>
      @deferTimeout()

  # Expand path to `nack_worker` command
  getNackWorkerPath: (callback) ->
    if @nackWorkerPath?
      callback null, @nackWorkerPath
    else
      exec 'which nack_worker', (error, stdout, stderr) =>
        if error
          # Throw an exception if `nack_worker` isn't in the `PATH`.
          #
          # Probably need to `gem install nack` or fix shitty rubygems
          callback new Error "Couldn't find `nack_worker` in PATH"
        else
          @nackWorkerPath = stdout.replace /(\n|\r)+$/, ''
          callback error, @nackWorkerPath

  spawn: () ->
    # Do nothing if the process is already started
    return if @state

    # Change start to `spawning` and fire an event
    @changeState 'spawning'

    @getNackWorkerPath (err, nackWorker) =>
      # Bubble error from `getNackWorkerPath`
      return @emit 'error', err if err

      # Generate a random sock path
      tmp = tmpFile()
      @sockPath = "#{tmp}.sock"
      @pipePath = "#{tmp}.pipe"

      createPipeStream @pipePath, (err, pipe) =>
        return @emit 'error', err if err

        args = ['--file', @sockPath, '--pipe', @pipePath]
        args.push '--debug' if @debug
        args.push @config

        # Spawn a Ruby server connecting to our `@sockPath`
        @child = spawn nackWorker, args,
          cwd: @cwd
          env: process.env

        # Expose `stdout` and `stderr` on Process
        @stdout = @child.stdout
        @stderr = @child.stderr

        pipe.on 'end', () =>
          pipe = null
          @pipe = fs.createWriteStream @pipePath
          @pipe.on 'open', () =>
            @changeState 'ready'

        # When the child process exists, clear out state and
        # emit `exit`
        @child.on 'exit', (code, signal) =>
          @clearTimeout()
          @pipe.end() if @pipe

          @state = @sockPath = @pipePath = null
          @child = @pipe = null
          @stdout = @stderr = null

          @emit 'exit'

        @emit 'spawn'

    this

  # Register a callback to only run once on the next event.
  onNext: (event, listener) ->
    callback = (args...) =>
      @removeListener event, callback
      listener args...
    @on event, callback

  # Change the current state and fire a corresponding event
  changeState: (state) ->
    if @state != state
      @state = state
      # State change events are always asynchronous
      process.nextTick => @emit state

  # Wait for state and invoke the callback.
  onState: (state, callback) ->
    # If we're already in the state, just do it
    if @state == state
      callback()
    else
      # Wait for next state change and check again
      @onNext state, =>
        @onState state, callback

  # Clear current timeout handler.
  clearTimeout: ->
    if @_timeoutId
      clearTimeout @_timeoutId

  # Defer the current idle timer.
  deferTimeout: ->
    if @idle
      # Clear the current timer
      @clearTimeout()

      callback = =>
        @emit 'idle'
        @quit()

      # Register a new timer
      @_timeoutId = setTimeout callback, @idle

  # Create a new **Client** connection
  createConnection: (callback) ->
    # Start child process if we haven't already
    @spawn()

    # Wait till the process is ready
    @onState 'ready', =>
      # Immediately flag process as `busy`
      @changeState 'busy'

      # Create a connection to our sock path
      connection = client.createConnection @sockPath

      # When the connection closes, change the state back
      # to ready.
      connection.on 'close', () =>
        @changeState 'ready'

      callback connection

  # Proxies a `http.ServerRequest` and `http.ServerResponse` to the process
  proxyRequest: (req, res, callback) ->
    # Pause request so we don't miss any `data` or `end` events.
    resume = pause req

    @createConnection (connection) ->
      connection.proxyRequest req, res

      if callback
        connection.on 'error', callback
        connection.on 'close', callback

      # Flush any events captured while we were establishing
      # our client connection
      resume()

  # Send `SIGTERM` to process.
  # This will immediately kill it.
  terminate: ->
    if @child
      @changeState 'quitting'
      @child.kill 'SIGTERM'

  # Send `SIGTERM` to process.
  # The process will finish serving its request and gracefully quit.
  quit: ->
    if @child
      @changeState 'quitting'
      @child.kill 'SIGQUIT'

# Public API for creating a **Process**
exports.createProcess = (args...) ->
  new Process args...

# Generates a random path.
tmpFile = () ->
  pid  = process.pid
  rand = Math.floor Math.random() * 10000000000
  "/tmp/nack." + pid + "." + rand

createPipeStream = (path, callback) ->
  exec "mkfifo #{path}", (error, stdout, stderr) =>
    if error?
      callback error
    else
      stream = fs.createReadStream path
      callback null, stream
