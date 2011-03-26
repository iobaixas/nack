{EventEmitter}  = require 'events'
{createProcess} = require './process'
{isFunction}    = require './util'

# A **Pool** manages multiple Ruby worker process.
#
# A Pool requires a path to a rackup file _(config.ru)_.
#
#     pool.createPool("/path/to/app/config.ru");
#
# Like Process, you can pass in an idle time in ms.
#
# You can a also set the max number of workers to spawn.
#
#     pool.createPool("/path/to/app/config.ru", { size: 5 });
#
# A Pool is an EventEmitter with the following events:
#
# > **Event 'worker:ready'**
# >
# > `function (process) { }`
# >
# >  Emitted when a worker process is 'ready'.
# >
# > **Event 'worker:spawn'**
# >
# > `function (process) { }`
# >
# > Emitted when a worker process has spawned.
# >
# > **Event 'worker:busy'**
# >
# > `function (process) { }`
# >
# > Emitted when a worker process becomes busy.
# >
# > **Event 'worker:exit'**
# >
# > `function (process) { }`
# >
# > Emitted when a worker process exitss
# >
# > **Event 'ready'**
# >
# > `function () { }`
# >
# > Emitted when at least one worker in the pool is ready.
# >
# > **Event 'exit'**
# >
# > `function () { }`
# >
# > Emitted when all the workers in the pool have exited.
#
exports.Pool = class Pool extends EventEmitter
  constructor: (@config, options) ->
    options ?= {}
    options.size ?= 1

    @workers = []
    @round = 0

    @processOptions =
      idle:  options.idle
      cwd:   options.cwd
      env:   options.env

    # Initialize aggregate streams
    @stdout = new AggregateStream
    @stderr = new AggregateStream

    self = @

    # When a worker becomes ready, check if the ready worker count moved
    # from 0 to 1
    previousReadyWorkerCount = 0
    @on 'worker:ready', ->
      newReadyWorkerCount = self.getReadyWorkerCount()
      if previousReadyWorkerCount is 0 and newReadyWorkerCount > 0
        self.emit 'ready'
      previousReadyWorkerCount = newReadyWorkerCount

    # When a worker exists, check if the alive worker count goes down to 0
    @on 'worker:exit', ->
      if self.getAliveWorkerCount() is 0
        self.emit 'exit'

    # Add `options.size` workers to the pool
    for n in [1..options.size]
      @increment()

  # Get number of workers whose state is not null
  getAliveWorkerCount: ->
    count = 0
    for worker in @workers when worker.state
      count++
    count

  # Get number of workers whose state is 'ready'
  getReadyWorkerCount: ->
    count = 0
    for worker in @workers when worker.state is 'ready'
      count++
    count

  # Returns the next worker
  nextWorker: ->
    # Prefer ready workers
    for worker in @workers when worker.state is 'ready'
      return worker

    # Choose next round robin style
    worker = @workers[@round]
    @round += 1
    @round %= @workers.length
    worker

  # Add a process to the pool
  increment: ->
    # Create a new process
    process = createProcess @config, @processOptions

    # Push it onto the workers list
    @workers.push process

    self = this

    process.on 'spawn', ->
      # Add the processes stdout and stderr to aggregate streams
      self.stdout.add process.stdout, process
      self.stderr.add process.stderr, process
      self.emit 'worker:spawn', process

    process.on 'ready', ->
      self.emit 'worker:ready', process

    process.on 'busy', ->
      self.emit 'worker:busy', process

    process.on 'error', (error) ->
      self.emit 'worker:error', process, error

    process.on 'exit', ->
      self.emit 'worker:exit', process

    process

  # Remove a process from the pool
  decrement: ->
    # Remove a process from the worker list
    if worker = @workers.shift()
      # and tell it to quit
      worker.quit()

  # Eager spawn all the workers in the pool
  spawn: ->
    for worker in @workers
      worker.spawn()

  # Tell everyone to terminate
  terminate: ->
    for worker in @workers
      worker.terminate()

  # Tell everyone to die
  quit: ->
    for worker in @workers
      worker.quit()

  # Restart active workers
  restart: (callback) ->
    if @getAliveWorkerCount() is 0
      callback?()
    else
      @once 'worker:ready', -> callback() if callback?

      for worker in @workers when worker.state
        worker.restart()

  # Proxies `http.ServerRequest` and `http.ServerResponse` to a worker.
  proxy: (req, res, next) =>
    worker = @nextWorker()
    worker.proxy req, res, next

# Public API for creating a **Pool*
exports.createPool = (args...) ->
  new Pool args...

# **AggregateStream** takes multiple read stream and aggregates them into a
# single stream to listen on. Its used to aggregate all the workers stdout and
# stderr into one pool stdout and stderr streams.
class AggregateStream extends EventEmitter
  # Register a new stream and process
  add: (stream, process) ->
    self = this

    stream.on 'data', (data) ->
      self.emit 'data', data, process

    stream.on 'error', (exception) ->
      self.emit 'error', exception, process