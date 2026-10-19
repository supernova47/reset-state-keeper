angular.module('beamng.apps')
.directive('resetStateKeeperFuel', ['$timeout', function ($timeout) {
  return {
    templateUrl: '/ui/modules/apps/ResetStateKeeperFuel/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope) {
      scope.collapsed = true;
      // Use a period as the decimal separator so the English HUD stays consistent
      // even when the game itself is running in another language.
      scope.formatNumber = function (value, decimals) {
        value = Number(value);
        if (!isFinite(value)) value = 0;
        decimals = Math.max(0, Math.min(3, Number(decimals) || 0));
        return value.toFixed(decimals);
      };
      scope.toggleCollapsed = function () {
        scope.collapsed = !scope.collapsed;
      };

      // Keep this action identical to the F10 binding in resetStateKeeper.json.
      scope.clearSavedStates = function () {
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('extensions.resetStateKeeper.clearSavedStates()');
        }
      };

      scope.multiplier = 1.0;
      scope.sliderDraft = 1.0;
      scope.manualValue = 1.0;
      scope.presets = [1, 2, 5, 10, 20];
      scope.fuelAvailable = false;
      scope.fuelStatusReceived = false;
      scope.fuelCurrent = 0;
      scope.fuelCapacity = 0;
      scope.fuelDraft = 0;
      scope.fuelEditing = false;
      scope.fuelPercent = 0;
      scope.fuelPresets = [25, 50, 75, 100];

      function setDisplayedMultiplier(value) {
        value = Number(value);
        if (!isFinite(value)) return;
        value = Math.round(Math.max(0.1, Math.min(100, value)) * 10) / 10;
        scope.multiplier = value;
        scope.sliderDraft = Math.min(20, value);
        scope.manualValue = value;
      }

      scope.applyMultiplier = function (value) {
        value = Number(value);
        if (!isFinite(value)) return;
        value = Math.round(Math.max(0.1, Math.min(100, value)) * 10) / 10;
        setDisplayedMultiplier(value);
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('extensions.resetStateKeeper.setFuelConsumptionMultiplier(' + value.toFixed(1) + ')');
        }
      };

      scope.adjustMultiplier = function (delta) {
        scope.applyMultiplier(Math.round((scope.multiplier + delta) * 10) / 10);
      };

      function setFuelStatus(data) {
        if (!data) return;
        scope.fuelStatusReceived = data.detected === true;
        scope.fuelAvailable = data.available === true && Number(data.capacity) > 0;
        scope.fuelCurrent = Math.max(0, Number(data.current) || 0);
        scope.fuelCapacity = Math.max(0, Number(data.capacity) || 0);
        scope.fuelPercent = scope.fuelCapacity > 0 ? Math.max(0, Math.min(100, scope.fuelCurrent / scope.fuelCapacity * 100)) : 0;
        if (!scope.fuelEditing) scope.fuelDraft = Math.round(scope.fuelCurrent * 10) / 10;
      }

      scope.setFuelAmount = function (value) {
        value = Number(value);
        if (!isFinite(value) || !scope.fuelAvailable) return;
        value = Math.max(0, Math.min(scope.fuelCapacity, value));
        scope.fuelDraft = Math.round(value * 10) / 10;
        scope.fuelEditing = false;
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('extensions.resetStateKeeper.setFuelAmountLiters(' + value.toFixed(2) + ')');
        }
      };

      scope.setFuelPercent = function (percent) {
        if (!scope.fuelAvailable) return;
        scope.setFuelAmount(scope.fuelCapacity * Number(percent) / 100);
      };

      scope.fillTank = function () {
        scope.setFuelAmount(scope.fuelCapacity);
      };

      scope.$on('ResetStateKeeperMultiplierUpdate', function (event, data) {
        var value = data && typeof data.multiplier !== 'undefined' ? data.multiplier : data;
        scope.$evalAsync(function () { setDisplayedMultiplier(value); });
      });

      scope.$on('ResetStateKeeperFuelStatusUpdate', function (event, data) {
        scope.$evalAsync(function () { setFuelStatus(data); });
      });

      $timeout(function () {
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('extensions.resetStateKeeper.sendFuelConsumptionMultiplierToUI()');
          bngApi.engineLua('extensions.resetStateKeeper.sendFuelStatusToUI()');
        }
      }, 300);

      scope.$on('$destroy', function () {});
    }
  };
}]);
