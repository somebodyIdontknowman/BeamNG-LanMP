'use strict'

// LANMP main-menu integration.
// Adds a "Multiplayer" button to the BeamNG main menu (v0.34+ menu system)
// and auto-opens the host/join page once when the game loads, so the player
// is asked what they want to do right away.

export default angular.module('lanmp_menu', ['ui.router'])

.config(['$stateProvider', function ($stateProvider) {
  $stateProvider.state('menu.lanmp', {
    url: '/lanmp',
    templateUrl: '/ui/modModules/lanmp_menu/lanmp_menu.html',
    controller: 'lanmpMenuController',
  })
}])

.run(['$rootScope', '$state', '$timeout', function ($rootScope, $state, $timeout) {
  // Add the Multiplayer button to the main menu every time it builds.
  $rootScope.$on('MainMenuButtons', function (event, addButton) {
    addButton({
      translateid: 'Multiplayer',
      icon: '/ui/modModules/lanmp_menu/icon.svg',
      targetState: 'menu.lanmp',
    })
  })

  // Auto-open the multiplayer page the first time the main menu is ready,
  // so the host/join choice appears as soon as the game loads.
  var autoOpened = false
  $rootScope.$on('MainMenuButtons', function () {
    if (autoOpened) return
    autoOpened = true
    $timeout(function () { $state.go('menu.lanmp') }, 50)
  })
}])

.controller('lanmpMenuController', ['$scope', '$timeout', '$state',
  function ($scope, $timeout, $state) {
    $scope.view = 'choose' // choose | host | join (connected view is driven by d.state)
    $scope.hostRunning = false

    $scope.d = {
      state: 'disconnected',
      status: 'Not connected',
      lastError: '',
      host: '127.0.0.1',
      port: 4144,
      serverName: '',
      username: '',
      ping: 0,
      players: [],
      chat: [],
      pin: '',
    }
    $scope.form = { host: '127.0.0.1', port: 4144, username: '', pin: '' }
    $scope.host = { name: "LANMP Server", port: 4144, maxPlayers: 8, map: "/levels/gridmap_v2/info.json", closed: false }
    $scope.chatMsg = ''
    $scope.nametags = true
    $scope.servers = []
    $scope.scanning = false

    function lua(cmd) { bngApi.engineLua(cmd) }
    function q(s) { return JSON.stringify(String(s === undefined ? '' : s)) }

    // BeamNG keeps swallowing keystrokes for vehicle controls unless the UI
    // says it owns the keyboard.
    $scope.focus = function (hasFocus) {
      lua('core_input_actionFilter.setGroup("lanmpUI", {"vehicleMenues","vehicleSwitching"})')
      lua('core_input_actionFilter.addAction(0, "lanmpUI", ' + (hasFocus ? 'true' : 'false') + ')')
    }

    // ---- view routing ----
    $scope.goChoose = function () { $scope.view = 'choose' }
    $scope.goHost = function () { $scope.view = 'host' }
    $scope.goJoin = function () {
      $scope.view = 'join'
      $scope.scan()
    }

    // ---- join ----
    $scope.connect = function () {
      $scope.d.lastError = ''
      lua('lanmp_session.connect(' + q($scope.form.host) + ', ' + (parseInt($scope.form.port, 10) || 4144) +
          ', ' + q($scope.form.username) + ', ' + q($scope.form.pin) + ')')
    }
    $scope.register = function () {
      $scope.d.lastError = ''
      lua('lanmp_session.registerAccount(' + q($scope.form.host) + ', ' +
          (parseInt($scope.form.port, 10) || 4144) + ', ' + q($scope.form.username) + ')')
    }
    $scope.disconnect = function () { lua('lanmp_session.disconnect()') }

    $scope.scan = function () {
      $scope.scanning = true
      $scope.servers = []
      lua('lanmp_discovery.scan()')
    }
    $scope.pick = function (server) {
      $scope.form.host = server.host
      $scope.form.port = server.port
    }

    // ---- host ----
    $scope.startHosting = function () {
      $scope.d.lastError = ''
      var port = parseInt($scope.host.port, 10) || 4144
      var maxPlayers = parseInt($scope.host.maxPlayers, 10) || 8
      var cmd = 'lanmp_host.startServer({name=' + q($scope.host.name) +
        ', port=' + port + ', maxPlayers=' + maxPlayers +
        ', map=' + q($scope.host.map) + ', closed=' + ($scope.host.closed ? 'true' : 'false') + '})'
      lua(cmd)
      $scope.hostRunning = true
      // Give the server a moment to bind, then connect to it locally.
      $timeout(function () {
        $scope.form.host = '127.0.0.1'
        $scope.form.port = port
        $scope.connect()
      }, 600)
    }
    $scope.stopHosting = function () {
      lua('lanmp_host.stopServer()')
      $scope.hostRunning = false
      if ($scope.d.state === 'connected') { $scope.disconnect() }
    }

    // ---- chat / nametags ----
    $scope.sendChat = function () {
      if (!$scope.chatMsg) return
      lua('lanmp_session.sendChatMessage(' + q($scope.chatMsg) + ')')
      $scope.chatMsg = ''
    }
    $scope.chatKey = function (e) { if (e.keyCode === 13) $scope.sendChat() }
    $scope.toggleNametags = function () {
      lua('lanmp_nametags.setEnabled(' + ($scope.nametags ? 'true' : 'false') + ')')
    }

    function scrollChat() {
      $timeout(function () {
        var box = document.getElementById('lanmp-msgs-menu')
        if (box) box.scrollTop = box.scrollHeight
      }, 0)
    }

    // ---- events from Lua ----
    $scope.$on('LanmpUpdate', function (event, data) {
      if (!data) return
      $scope.$evalAsync(function () {
        var wasChat = $scope.d.chat ? $scope.d.chat.length : 0
        $scope.d = data
        if (data.username && !$scope.form.username) $scope.form.username = data.username
        if (data.pin) $scope.form.pin = data.pin
        if (data.nametags !== undefined) $scope.nametags = data.nametags
        if (data.chat && data.chat.length !== wasChat) scrollChat()
        // If we dropped out of connected, reflect hostRunning too.
        if (data.state === 'disconnected' && $scope.hostRunning) {
          // server may still be running; leave hostRunning as-is so user can stop it
        }
      })
    })

    $scope.$on('LanmpServers', function (event, data) {
      if (!data) return
      $scope.$evalAsync(function () {
        $scope.scanning = data.scanning
        $scope.servers = data.servers || []
      })
    })

    $scope.$on('$destroy', function () {
      // Release the keyboard when leaving the page.
      try { $scope.focus(false) } catch (e) {}
    })

    // Ask the Lua side for current state and kick off a scan in case the
    // player goes straight to Join.
    bngApi.engineLua('if lanmp_session then lanmp_session.requestState() end')
    bngApi.engineLua('if lanmp_host then lanmp_host.refreshUI() end')
  }
])
