'use strict'

import '../../modules/overhaulAngular/musicPlayer.js'

angular.module('beamng.stuff')
.controller('OverhaulManagerController', ['$scope', function($scope) {
  $scope.devKeyValid = false;
  $scope.isLoaded = false;
  $scope.isDirty = false;
  $scope.isSaving = false;
  $scope.saveStatus = '';
  $scope.saveError = false;

  $scope.toggles = {
    mapDevMode: false,
    noParkedMode: false,
    forcePhoneTutorial: false,
    racingTeamDevConsole: false,
    realisticVehicleEntry: true,
    realisticWalkingCamera: true,
    showBusPassengers: true,
    autosaveEnabled: true
  };

  $scope.autosaveIntervals = [5, 10, 15, 30, 60];
  $scope.autosaveIntervalMinutes = 5;
  $scope.autosaveIntervalIndex = 0;

  function getCurrentSettings() {
    return {toggles: angular.copy($scope.toggles), autosaveIntervalMinutes: $scope.autosaveIntervalMinutes};
  }

  var savedSettings = getCurrentSettings();

  function markDirty() {
    $scope.isDirty = !angular.equals(getCurrentSettings(), savedSettings);
  }

  function setToggle(key, value) {
    $scope.toggles[key] = value;
    $scope.saveStatus = '';
    $scope.saveError = false;
    markDirty();
  }

  $scope.loadSettings = function() {
    bngApi.engineLua("extensions.overhaul_shell_extensionManager.isDevKeyValid()", function(result) {
      $scope.$evalAsync(function() {
        $scope.devKeyValid = result === true;
      });
    });

    bngApi.engineLua("extensions.overhaul_shell_settings.getSettings()", function(result) {
      $scope.$evalAsync(function() {
        var loadedSettings = result || {};
        Object.keys($scope.toggles).forEach(function(key) {
          if (typeof loadedSettings[key] === 'boolean') {
            $scope.toggles[key] = loadedSettings[key];
          }
        });

        if ($scope.autosaveIntervals.indexOf(loadedSettings.autosaveIntervalMinutes) !== -1) {
          $scope.autosaveIntervalMinutes = loadedSettings.autosaveIntervalMinutes;
          $scope.autosaveIntervalIndex = $scope.autosaveIntervals.indexOf(loadedSettings.autosaveIntervalMinutes);
        }
        savedSettings = getCurrentSettings();
        $scope.isLoaded = true;
        $scope.isDirty = false;
      });
    });
  };

  $scope.toggleMapDevMode = function() {
    setToggle('mapDevMode', !$scope.toggles.mapDevMode);
  };

  $scope.toggleAutosave = function() {
    setToggle('autosaveEnabled', !$scope.toggles.autosaveEnabled);
  };

  $scope.toggleNoParkedMode = function() {
    setToggle('noParkedMode', !$scope.toggles.noParkedMode);
  };

  $scope.toggleRealisticVehicleEntry = function() {
    setToggle('realisticVehicleEntry', !$scope.toggles.realisticVehicleEntry);
  };

  $scope.toggleRealisticWalkingCamera = function() {
    setToggle('realisticWalkingCamera', !$scope.toggles.realisticWalkingCamera);
  };

  $scope.toggleShowBusPassengers = function() {
    setToggle('showBusPassengers', !$scope.toggles.showBusPassengers);
  };

  $scope.toggleForcePhoneTutorial = function() {
    if (!$scope.devKeyValid) return;
    setToggle('forcePhoneTutorial', !$scope.toggles.forcePhoneTutorial);
  };

  $scope.toggleRacingTeamDevConsole = function() {
    if (!$scope.devKeyValid) return;
    setToggle('racingTeamDevConsole', !$scope.toggles.racingTeamDevConsole);
  };

  $scope.setAutosaveInterval = function(minutes) {
    if ($scope.autosaveIntervals.indexOf(minutes) === -1) return;
    $scope.autosaveIntervalMinutes = minutes;
    $scope.autosaveIntervalIndex = $scope.autosaveIntervals.indexOf(minutes);
    $scope.saveStatus = '';
    $scope.saveError = false;
    markDirty();
  };

  $scope.replayPhoneTutorial = function() {
    if (!$scope.devKeyValid) return;
    bngApi.engineLua("extensions.overhaul_shell_extensionManager.replayPhoneTutorial()");
  };

  $scope.saveSettings = function() {
    if (!$scope.isDirty || $scope.isSaving) return;

    var luaSettings = Object.keys($scope.toggles).map(function(key) {
      return key + '=' + ($scope.toggles[key] === true ? 'true' : 'false');
    });
    luaSettings.push('autosaveIntervalMinutes=' + Number($scope.autosaveIntervalMinutes));
    luaSettings = luaSettings.join(',');

    $scope.isSaving = true;
    $scope.saveStatus = 'Saving changes…';
    $scope.saveError = false;

    bngApi.engineLua("extensions.overhaul_shell_settings.setSettings({" + luaSettings + "})", function(result) {
      $scope.$evalAsync(function() {
        $scope.isSaving = false;
        if (result === true) {
          savedSettings = getCurrentSettings();
          $scope.isDirty = false;
          $scope.saveStatus = 'Changes saved';
          return;
        }

        $scope.saveError = true;
        $scope.saveStatus = 'Could not save changes';
      });
    });
  };

  $scope.goBack = function() {
    bngApi.engineLua("extensions.ui_router.back()");
  };

  $scope.loadSettings();
}])

export default angular.module('overhaulManager', ['ui.router', 'rlsMusicPlayer'])

.config(['$stateProvider', function($stateProvider) {
  $stateProvider.state('menu.overhaulManager', {
    url: '/overhaulManager',
    templateUrl: '/ui/modModules/overhaulManager/overhaulManager.html?v=9',
    controller: 'OverhaulManagerController',
  })
}])

.run(['$rootScope', function ($rootScope) {
  const buttonConfig = {
    icon: '/ui/modModules/overhaulManager/icons/overhaulIcon.png',
    targetState: 'menu.overhaulManager',
    translateid: 'Overhaul Manager'
  };

  function addOverhaulManagerButton(addButton) {
    if (typeof addButton === 'function') {
      addButton(buttonConfig)
    }
  }

  $rootScope.$on("MainMenuButtons", function(_event, addButton) {
    addOverhaulManagerButton(addButton)
  })

  if (window.bridge && window.bridge.events) {
    window.bridge.events.on("MainMenuButtons", addOverhaulManagerButton)
  }

  bngApi.engineLua("guihooks.trigger('BroadcastMainMenuButtons')")
}])
