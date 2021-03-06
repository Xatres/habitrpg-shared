_ = require 'lodash'
expect = require 'expect.js'
sinon = require 'sinon'
moment = require 'moment'

# Custom modules
algos = require '../script/algos.coffee'
helpers = require '../script/helpers.coffee'
items = require '../script/items.coffee'

### Helper Functions ####
expectStrings = (obj, paths) ->
  _.each paths, (path) -> expect(obj[path]).to.be.ok()

# options.daysAgo: days ago when the last cron was executed
beforeAfter = (options={}) ->
  user = helpers.newUser()
  [before, after] = [_.cloneDeep(user), _.cloneDeep(user)]
  before.preferences.dayStart = after.preferences.dayStart = options.dayStart if options.dayStart
  before.preferences.timezoneOffset = after.preferences.timezoneOffset = (options.timezoneOffset or moment().zone())
  if options.limitOne
    before["#{options.limitOne}s"] = [before["#{options.limitOne}s"][0]]
    after["#{options.limitOne}s"] = [after["#{options.limitOne}s"][0]]
  lastCron = +(moment(options.now || +new Date).subtract('days', options.daysAgo)) if options.daysAgo
  _.each [before,after], (obj) ->
    obj.lastCron = lastCron if options.daysAgo
  {before:before, after:after}
#TODO calculate actual poins

expectLostPoints = (before, after, taskType) ->
  if taskType in ['daily','habit']
    expect(after.stats.hp).to.be.lessThan before.stats.hp
    expect(after["#{taskType}s"][0].history).to.have.length(1)
  else expect(after.history.todos).to.have.length(1)
  expect(after.stats.exp).to.be 0
  expect(after.stats.gp).to.be 0
  expect(after["#{taskType}s"][0].value).to.be.lessThan before["#{taskType}s"][0].value

expectGainedPoints = (before, after, taskType) ->
  expect(after.stats.hp).to.be 50
  expect(after.stats.exp).to.be.greaterThan before.stats.exp
  expect(after.stats.gp).to.be.greaterThan before.stats.gp
  expect(after["#{taskType}s"][0].value).to.be.greaterThan before["#{taskType}s"][0].value
  expect(after["#{taskType}s"][0].history).to.have.length(1) if taskType is 'habit'
  # daily & todo histories handled on cron

expectNoChange = (before,after) -> expect(before).to.eql after

expectDayResetNoDamage = (b,a) ->
  [before,after] = [_.cloneDeep(b); _.cloneDeep(a)]
  _.each after.dailys, (task,i) ->
    expect(task.completed).to.be false
    expect(before.dailys[i].value).to.be task.value
    expect(before.dailys[i].streak).to.be task.streak
    expect(task.history).to.have.length(1)
  _.each after.todos, (task,i) ->
    expect(task.completed).to.be false
    expect(before.todos[i].value).to.be.greaterThan task.value
  expect(after.history.todos).to.have.length(1)
  # hack so we can compare user before/after obj equality sans effected paths
  _.each ['dailys','todos','history','lastCron'], (path) ->
    _.each [before,after], (obj) -> delete obj[path]
  delete after._tmp
  expect(after).to.eql before

cycle = (array)->
  n = -1
  ->
    n++
    return array[n % array.length]

repeatWithoutLastWeekday = ()->
  repeat = {su:1,m:1,t:1,w:1,th:1,f:1,s:1}
  if helpers.startOfWeek(moment().zone(0)).isoWeekday() == 1 # Monday
    repeat.su = false
  else
    repeat.s = false
  {repeat: repeat}

###### Specs ######

describe 'User', ->
  it 'sets correct user defaults', ->
    user = helpers.newUser()
    expect(user.stats).to.eql { gp: 0, exp: 0, lvl: 1, hp: 50 }
    expect(user.items.weapon).to.eql 0
    expect(user.items.armor).to.eql 0
    expect(user.items.head).to.eql 0
    expect(user.items.shield).to.eql 0
    expect(user.items.lastDrop.count).to.eql 0
    expect(user.preferences).to.eql { gender: 'm', skin: 'white', hair: 'blond', armorSet: 'v1', dayStart:0, showHelm: true }
    expect(user.balance).to.eql 0
    expect(user.lastCron).to.be.greaterThan 0
    expect(user.flags).to.eql {partyEnabled: false, itemsEnabled: false, ads: 'show'}
    expectStrings(user, ['apiToken'])
    expectStrings(user.habits[0], ['text','id'])
    expectStrings(user.dailys[0], ['text','id'])
    expectStrings(user.todos[0], ['text','id'])
    expectStrings(user.rewards[0], ['text','id'])
    expectStrings(user.tags[0], ['name','id'])
    expectStrings(user.tags[1], ['name','id'])
    expectStrings(user.tags[2], ['name','id'])

  it 'revives correctly', ->
    user = helpers.newUser()
    user.stats = { gp: 10, exp: 100, lvl: 2, hp: 1 }
    user.weapon = 1
    algos.revive user
    expect(user.stats).to.eql { gp: 0, exp: 0, lvl: 1, hp: 50 }
    expect(user.items.weapon).to.eql 0
    expect(user.items.armor).to.eql 0
    expect(user.items.head).to.eql 0
    expect(user.items.shield).to.eql 0

  describe 'store', ->
    it 'recovers hp buying potions', ->
      user = helpers.newUser()
      user.stats.hp = 30
      user.stats.gp = 50
      expect(items.buyItem user, 'potion').to.be true
      expect(user.stats.hp).to.eql 45
      expect(user.stats.gp).to.eql 25

      expect(items.buyItem user, 'potion').to.be true
      expect(user.stats.hp).to.eql 50 # don't exceed max hp
      expect(user.stats.gp).to.eql 0

    it 'buys equipment', ->
      user = helpers.newUser()
      user.stats.gp = 31
      expect(items.buyItem user, 'armor').to.be true
      expect(user.items.armor).to.eql 1
      expect(user.stats.gp).to.eql 1

    it 'do not buy equipment without enough money', ->
      user = helpers.newUser()
      user.stats.gp = 1
      expect(items.buyItem user, 'armor').to.be false
      expect(user.items.armor).to.eql 0
      expect(user.stats.gp).to.eql 1

  describe 'drop system', ->
    user = null

    beforeEach ->
      user = helpers.newUser()
      user.flags.dropsEnabled = true
      # too many Math.random calls to stub, let's return the last element
      sinon.stub(helpers, 'randomVal', (obj)->
        result = undefined
        for key, val of obj
          result = val
        result
      )

    it 'gets a golden potion', ->
      sinon.stub(Math, 'random').returns 0
      algos.score(user, user.dailys[0], 'up')
      expect(user.items.eggs).to.eql {}
      expect(user.items.hatchingPotions).to.eql {'Golden': 1}

    it 'gets a bear cub egg', ->
      sinon.stub(Math, 'random', cycle [0, 0.55])
      algos.score(user, user.dailys[0], 'up')
      expect(user.items.eggs).to.eql {'BearCub': 1}
      expect(user.items.hatchingPotions).to.eql {}

    it 'does not get a drop', ->
      sinon.stub(Math, 'random').returns 0.5
      algos.score(user, user.dailys[0], 'up')
      expect(user.items.eggs).to.eql {}
      expect(user.items.hatchingPotions).to.eql {}

    afterEach ->
      Math.random.restore()
      helpers.randomVal.restore()

describe 'Simple Scoring', ->

  it 'Habits : Up', ->
    {before,after} = beforeAfter()
    algos.score(after, after.habits[0], 'down', {times:5})
    expectLostPoints(before,after,'habit')

  it 'Habits : Down', ->
    {before,after} = beforeAfter()
    algos.score(after, after.habits[0], 'up', {times:5})
    expectGainedPoints(before,after,'habit')

  it 'Dailys : Up', ->
    {before,after} = beforeAfter()
    algos.score(after, after.dailys[0], 'up')
    expectGainedPoints(before,after,'daily')

  it 'Todos : Up', ->
    {before,after} = beforeAfter()
    algos.score(after, after.todos[0], 'up')
    expectGainedPoints(before,after,'todo')

describe 'Cron', ->

  it 'computes shouldCron', ->
    user = helpers.newUser()

    paths = {};algos.cron user, {paths}
    expect(paths.lastCron).to.not.be.ok # it setup the cron property now

    user.lastCron = +moment().subtract('days',1)
    paths = {};algos.cron user, {paths}
    expect(paths.lastCron).to.be true

#    user.lastCron = +moment().add('days',1)
#    paths = {};algos.cron user, {paths}
#    expect(paths.lastCron).to.be true # busted cron (was set to after today's date)

  it 'only dailies & todos are effected', ->
    {before,after} = beforeAfter({daysAgo:1})
    before.dailys = before.todos = after.dailys = after.todos = []
    algos.cron(after)
    expect(after.lastCron).to.not.be before.lastCron # make sure cron was run
    expect(before.stats).to.eql after.stats
    beforeTasks = before.habits.concat(before.dailys).concat(before.todos).concat(before.rewards)
    afterTasks = after.habits.concat(after.dailys).concat(after.todos).concat(after.rewards)
    expect(beforeTasks).to.eql afterTasks

  it 'should preen user history', ->
    {before,after} = beforeAfter({daysAgo:1})
    history = [
      # Last year should be condensed to one entry, avg: 1
      {date:'09/01/2012', value: 0}
      {date:'10/01/2012', value: 0}
      {date:'11/01/2012', value: 2}
      {date:'12/01/2012', value: 2}

      # Each month of this year should be condensed to 1/mo, averages follow
      {date:'01/01/2013', value: 1} #2
      {date:'01/15/2013', value: 3}

      {date:'02/01/2013', value: 2} #3
      {date:'02/15/2013', value: 4}

      {date:'03/01/2013', value: 3} #4
      {date:'03/15/2013', value: 5}

      {date:'04/01/2013', value: 4} #5
      {date:'04/15/2013', value: 6}

      {date:'05/01/2013', value: 5} #6
      {date:'05/15/2013', value: 7}

      {date:'06/01/2013', value: 6} #7
      {date:'06/15/2013', value: 8}

      {date:'07/01/2013', value: 7} #8
      {date:'07/15/2013', value: 9}

      {date:'08/01/2013', value: 8} #9
      {date:'08/15/2013', value: 10}

      {date:'09/01/2013', value: 9} #10
      {date:'09/15/2013', value: 11}

      {date:'010/01/2013', value: 10} #11
      {date:'010/15/2013', value: 12}

      # This month should condense each week
      {date:'011/01/2013', value: 12}
      {date:'011/02/2013', value: 13}
      {date:'011/03/2013', value: 14}
      {date:'011/04/2013', value: 15}
    ]
    after.history = {exp: _.cloneDeep(history), todos: _.cloneDeep(history)}
    after.habits[0].history = _.cloneDeep(history)
    algos.cron(after)

    # remove history entries created by cron
    after.history.exp.pop()
    after.history.todos.pop()

    _.each [after.history.exp, after.history.todos, after.habits[0].history], (arr) ->
      expect(_.map(arr, (x)->x.value)).to.eql [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

  describe 'Todos', ->
    it '1 day missed', ->
      {before,after} = beforeAfter({daysAgo:1})
      before.dailys = after.dailys = []
      algos.cron(after)

      # todos don't effect stats
      expect(after.stats.hp).to.be 50
      expect(after.stats.exp).to.be 0
      expect(after.stats.gp).to.be 0

      # but they devalue
      expect(after.todos[0].value).to.be.lessThan before.todos[0].value
      expect(after.history.todos).to.have.length 1

  describe 'dailies', ->

    describe 'new day', ->

      ###
      This section runs through a "cron matrix" of all permutations (that I can easily account for). It sets
      task due days, user custom day start, timezoneOffset, etc - then runs cron, jumps to tomorrow and runs cron,
      and so on - testing each possible outcome along the way
      ###

      runCron = (options) ->
        _.each [480, 240, 0, -120], (timezoneOffset) -> # test different timezones
          now = helpers.startOfWeek({timezoneOffset}).add('hours', options.currentHour||0)
          {before,after} = beforeAfter({now, timezoneOffset, daysAgo:1, dayStart:options.dayStart||0, limitOne:'daily'})
          before.dailys[0].repeat = after.dailys[0].repeat = options.repeat if options.repeat
          before.dailys[0].streak = after.dailys[0].streak = 10
          before.dailys[0].completed = after.dailys[0].completed = true if options.checked
          if options.shouldDo
            expect(helpers.shouldDo(now, options.repeat, {timezoneOffset, dayStart:options.dayStart, now})).to.be.ok()
          algos.cron(after,{now})
          switch options.expect
            when 'losePoints' then expectLostPoints(before,after,'daily')
            when 'noChange' then expectNoChange(before,after)
            when 'noDamage' then expectDayResetNoDamage(before,after)
          {before,after}

      cronMatrix =
        steps:

          'due yesterday':
            defaults: {daysAgo:1, limitOne: 'daily'}
            steps:

              '(simple)': {expect:'losePoints'}

              'due today':
                # NOTE: a strange thing here, moment().startOf('week') is Sunday, but moment.zone(myTimeZone).startOf('week') is Monday.
                defaults: {repeat:{su:1,m:true,t:1,w:1,th:1,f:1,s:1}}
                steps:
                  'pre-dayStart':
                    defaults: {currentHour:3, dayStart:4, shouldDo:true}
                    steps:
                      'checked': {checked: true, expect:'noChange'}
                      'un-checked': {checked: false, expect:'noChange'}
                  'post-dayStart':
                    defaults: {currentHour:5, dayStart:4, shouldDo:true}
                    steps:
                      'checked': {checked:true, expect:'noDamage'}
                      'unchecked': {checked:false, expect: 'losePoints'}

              'NOT due today':
                defaults: {repeat:{su:1,m:false,t:1,w:1,th:1,f:1,s:1}}
                steps:
                  'pre-dayStart':
                    defaults: {currentHour:3, dayStart:4, shouldDo:true}
                    steps:
                      'checked': {checked: true, expect:'noChange'}
                      'un-checked': {checked: false, expect:'noChange'}
                  'post-dayStart':
                    defaults: {currentHour:5, dayStart:4, shouldDo:false}
                    steps:
                      'checked': {checked:true, expect:'noDamage'}
                      'unchecked': {checked:false, expect: 'losePoints'}

          'not due yesterday':
            defaults: repeatWithoutLastWeekday()
            steps:
              '(simple)': {expect:'noDamage'}
              'post-dayStart': {currentHour:5,dayStart:4, expect:'noDamage'}
              'pre-dayStart': {currentHour:3, dayStart:4, expect:'noChange'}

      recurseCronMatrix = (obj, options={}) ->
        if obj.steps
          _.each obj.steps, (step, text) ->
            o = _.cloneDeep options
            o.text ?= ''; o.text += " #{text} "
            recurseCronMatrix step, _.defaults(o,obj.defaults)
        else
          it "#{options.text}", -> runCron(_.defaults(obj,options))
      recurseCronMatrix(cronMatrix)

    it 'calculates day differences with dayStart properly', ->
      dayStart = 4
      yesterday = helpers.startOfDay {now: moment().subtract('d', 1), dayStart}
      now = helpers.startOfDay {dayStart: dayStart-1}
      expect(helpers.daysSince(yesterday, {now, dayStart})).to.eql 0
      now = moment().startOf('day').add('h', dayStart).add('m', 1)
      expect(helpers.daysSince(yesterday, {now, dayStart})).to.eql 1

describe 'Helper', ->
  it 'calculates gold coins', ->
    expect(helpers.gold(10)).to.eql 10
    expect(helpers.gold(1.957)).to.eql 1
    expect(helpers.gold()).to.eql 0

  it 'calculates silver coins', ->
    expect(helpers.silver(10)).to.eql 0
    expect(helpers.silver(1.957)).to.eql 95
    expect(helpers.silver(0.01)).to.eql "01"
    expect(helpers.silver()).to.eql "00"

  it 'calculates experience to next level', ->
    expect(algos.tnl 1).to.eql 150
    expect(algos.tnl 2).to.eql 160
    expect(algos.tnl 10).to.eql 260
    expect(algos.tnl 99).to.eql 3580
    expect(algos.tnl 100).to.eql 0

  it 'calculates priority values', ->
    expect(algos.priorityValue()).to.eql 1
    expect(algos.priorityValue '!').to.eql 1
    expect(algos.priorityValue '!!').to.eql 1.5
    expect(algos.priorityValue '!!!').to.eql 2
    expect(algos.priorityValue '!!!!').to.eql 1

  it 'calculates the start of the day', ->
    expect(helpers.startOfDay({now: new Date(2013, 0, 1, 0)}).format('YYYY-MM-DD HH:mm')).to.eql '2013-01-01 00:00'
    expect(helpers.startOfDay({now: new Date(2013, 0, 1, 5)}).format('YYYY-MM-DD HH:mm')).to.eql '2013-01-01 00:00'
    expect(helpers.startOfDay({now: new Date(2013, 0, 1, 23, 59, 59)}).format('YYYY-MM-DD HH:mm')).to.eql '2013-01-01 00:00'

  it 'counts pets', ->
    pets = {}
    expect(helpers.countPets(null, pets)).to.eql 0
    expect(helpers.countPets(1, pets)).to.eql 1

    pets = { "Dragon-Red": 1, "Wolf-Base": 2 }
    expect(helpers.countPets(null, pets)).to.eql 2
    expect(helpers.countPets(2, pets)).to.eql 2

    pets = { "Wolf-Base": 2, "Wolf-Veteran": 1, "Wolf-Cerberus": 1, "Dragon-Hydra": 1}
    expect(helpers.countPets(null, pets)).to.eql 1
    expect(helpers.countPets(_.size(pets), pets)).to.eql 1
