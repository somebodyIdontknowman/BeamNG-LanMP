angular.module('beamng.apps')
.directive('lanmp', ['$timeout', function ($timeout) {
  return {
    templateUrl: '/ui/modules/apps/lanmp/app.html',
    replace: true,
    restrict: 'EA',
    link: function (scope, element) {
      scope.d = {
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
        pin: ''
      };
      scope.form = { host: '127.0.0.1', port: 4144, username: '', pin: '' };
      scope.chatMsg = '';
      scope.nametags = true;

      function lua(cmd) { bngApi.engineLua(cmd); }
      function q(s) { return JSON.stringify(String(s === undefined ? '' : s)); }

      // BeamNG keeps swallowing keystrokes for vehicle controls unless the UI
      // says it owns the keyboard.
      scope.focus = function (hasFocus) {
        lua('core_input_actionFilter.setGroup("lanmpUI", {"vehicleMenues","vehicleSwitching"})');
        lua('core_input_actionFilter.addAction(0, "lanmpUI", ' + (hasFocus ? 'true' : 'false') + ')');
      };

      scope.connect = function () {
        scope.d.lastError = '';
        lua('lanmp_session.connect(' + q(scope.form.host) + ', ' + (parseInt(scope.form.port, 10) || 4144) +
            ', ' + q(scope.form.username) + ', ' + q(scope.form.pin) + ')');
      };

      scope.register = function () {
        scope.d.lastError = '';
        lua('lanmp_session.registerAccount(' + q(scope.form.host) + ', ' +
            (parseInt(scope.form.port, 10) || 4144) + ', ' + q(scope.form.username) + ')');
      };

      scope.disconnect = function () { lua('lanmp_session.disconnect()'); };

      scope.sendChat = function () {
        if (!scope.chatMsg) { return; }
        lua('lanmp_session.sendChatMessage(' + q(scope.chatMsg) + ')');
        scope.chatMsg = '';
      };

      scope.chatKey = function (e) { if (e.keyCode === 13) { scope.sendChat(); } };

      scope.toggleNametags = function () {
        lua('lanmp_nametags.setEnabled(' + (scope.nametags ? 'true' : 'false') + ')');
      };

      function scrollChat() {
        $timeout(function () {
          var box = element[0].querySelector('#lanmp-msgs');
          if (box) { box.scrollTop = box.scrollHeight; }
        }, 0);
      }

      scope.$on('LanmpUpdate', function (event, data) {
        if (!data) { return; }
        scope.$evalAsync(function () {
          var wasChat = scope.d.chat ? scope.d.chat.length : 0;
          scope.d = data;
          if (data.username && !scope.form.username) { scope.form.username = data.username; }
          if (data.pin) { scope.form.pin = data.pin; }
          if (data.nametags !== undefined) { scope.nametags = data.nametags; }
          if (data.chat && data.chat.length !== wasChat) { scrollChat(); }
        });
      });

      bngApi.engineLua('if lanmp_session then lanmp_session.requestState() end');
    }
  };
}]);
