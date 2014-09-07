# Standard node
os = require("os")
fs = require("fs")
util = require('util')

# Extra
redis = require("redis")
moment = require("moment")
Tail = require("tail").Tail
_ = require("underscore")
glob = require("glob")
log = require('log4node')
argv = require('optimist').argv


# Log config
class LogConfig
  CONFIG_FILENAME: "/etc/log-shipper/log-shipper.json"

  constructor: () ->
    # Load the config
    @reload()

    # Parse arguments
    @parseArgv()

  parseArgv: ->
    if argv.debug or argv.v
        log.reconfigure
            level: 'debug'

        log.debug "Debug mode on"

  reload: () ->
    try
      @config = JSON.parse(fs.readFileSync(@CONFIG_FILENAME, 'utf8'))
    catch e
      throw new Error("Error loading config file")

class Redis
  constructor: (config) ->
    # Create the redis client
    @client = redis.createClient config.redis.port, config.redis.host,
      auth_pass: config.redis.auth ? null

    @client.on "error", (error) ->
        # Check if this is a savable event
        if error.message.indexOf("ECONNREFUSED") > -1
            # Just log it out
            log.error error
        else
            # Otherwise, die
            throw error

    @client.on "ready", ->
        log.info "Redis connection ready."

    @client.on "end", =>
        log.error "Connection to Redis lost."

    @config = config

  send: (message, filename) ->
    @client.rpush @config.redis.key, message, () ->
        log.debug "Emit for: #{filename}"

  quit: ->
    @client.quit()

# Defines a set of Listeners
class Listeners
  constructor: ->
    @listeners = []

  add_listener: (listener) ->
    @listeners.push listener

  stop_all: ->
    _.each @listeners, (listener, index, list) ->
      listener.stop()

  clear: ->
    @listeners = []

# Defines a listener
class Listener
  constructor: (log_shipper, filename, file_object) ->
    @config = log_shipper.log_config.config
    @hostname = log_shipper.hostname
    @filename = filename
    @file_object = file_object
    @redis_client = log_shipper.redis_client

    # Setup the emit event handler
    try
      @tail = new Tail filename
      @tail.on "line", @onLineEvent
    catch e
      log.error "Problem reading: #{filename}"
      throw e

    log.info "Now watching: " + @filename

    return

  onLineEvent: (newLine) =>
    @send @createLog newLine
    return

  createLog: (message) =>
    JSON.stringify
      "@timestamp": moment.utc().format()
      "@version": 1
      "host": @hostname
      "message": message
      "path": @filename
      "type": @file_object.type

  stop: () ->
    @tail.unwatch()

  send: (log_message) =>
    @redis_client.send log_message, @filename

class LiteLogShipper
  constructor: () ->
    # New log config object
    @log_config = new LogConfig

    # Redis client instance
    @redis_client = new Redis @log_config.config

    # Listeners instance
    @listeners = new Listeners

    # Get hostname
    @hostname = os.hostname()

    # Startup
    log.info "Starting up"
    @setupListeners()

    # Set up hooks
    process.on 'SIGINT', @cleanUpAndExit
    process.on 'SIGTERM', @cleanUpAndExit
    process.on 'SIGHUP', @reloadConfig

  # Sets up the listeners
  setupListeners: =>
    # Enter each "files"
    _.each @log_config.config.files, (file_object) =>
      # Get every "paths"
      _.each file_object.paths, (path) =>
        # Glob them
        glob path, (er, files) =>
          # Filter through each of them
          _.each files, (path) =>
            @listeners.add_listener new Listener this, path, file_object
            return
          return
        return
      return
    return

  reloadConfig: =>
    log.info "Config reload requested"
    log.info "Stopping all current listeners"

    # Stop and clear all listeners
    @listeners.stop_all()
    @listeners.clear()

    log.info "All listeners stopped"
    log.info "Reloadig config"

    # Reload config
    @log_config.reload()

    log.info "Starting up listeners"
    @setupListeners()

  cleanUpAndExit: =>
    log.info "Recieved shutdown signal, will close client..."

    # Close the client
    @redis_client.quit()

    log.info "Client closed"
    log.info "Shutting down"
    process.exit()

new LiteLogShipper
