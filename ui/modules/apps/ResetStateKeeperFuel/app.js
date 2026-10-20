angular.module('beamng.apps')
.directive('resetStateKeeperFuel', ['$timeout', function ($timeout) {
  return {
    templateUrl: '/ui/modules/apps/ResetStateKeeperFuel/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element) {
      scope.collapsed = true;
      try {
        var savedCollapsed = window.localStorage.getItem('resetStateKeeperFuel.collapsed');
        if (savedCollapsed !== null) scope.collapsed = savedCollapsed === 'true';
      } catch (e) {}
      var floatingHud = attachFloatingCollapse(scope, element, 'resetStateKeeperFuel.collapsedPosition', '.rskFuelRestoreButton');
      // Use a period as the decimal separator so the English HUD stays consistent
      // even when the game itself is running in another language.
      scope.formatNumber = function (value, decimals) {
        value = Number(value);
        if (!isFinite(value)) value = 0;
        decimals = Math.max(0, Math.min(3, Number(decimals) || 0));
        return value.toFixed(decimals);
      };
      scope.toggleCollapsed = function () {
        if (!floatingHud.toggle()) return;
        try { window.localStorage.setItem('resetStateKeeperFuel.collapsed', String(scope.collapsed)); } catch (e) {}
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

      scope.$on('$destroy', function () { floatingHud.destroy(); });
    }
  };
}]);

function attachFloatingCollapse(appScope, appElement, positionKey, restoreSelector) {
  var iconSize = 34;
  var itemElement = null;
  var frameElement = null;
  var overlayElement = null;
  var expandedSize = null;
  var lastAppliedBounds = null;
  var layoutStyle = null;
  var editStartStyle = null;
  var expandedFromIcon = false;
  var isReady = false;
  var isDestroyed = false;
  var wasEditing = false;
  var drag = null;
  var suppressClick = false;
  var resizeObserver = null;
  var overlayObserver = null;
  var itemStyleObserver = null;
  var position = readPosition();
  var rootElement = appElement && appElement[0] ? appElement[0] : appElement;

  function readPosition() {
    try {
      var saved = JSON.parse(window.localStorage.getItem(positionKey) || 'null');
      if (saved && isFinite(Number(saved.x)) && isFinite(Number(saved.y))) {
        return { x: clamp(Number(saved.x), 0, 1), y: clamp(Number(saved.y), 0, 1) };
      }
    } catch (e) {}
    return null;
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function schedule(callback) {
    var request = window.requestAnimationFrame || function (fn) { return window.setTimeout(fn, 0); };
    request(function () { if (!isDestroyed) callback(); });
  }

  function findElements() {
    if (!itemElement && rootElement && rootElement.closest) itemElement = rootElement.closest('.overlay-item');
    if (!frameElement && itemElement) frameElement = itemElement.closest('.overlay__frame') || itemElement.parentElement;
    if (!overlayElement && frameElement && frameElement.closest) overlayElement = frameElement.closest('.overlay');
    return !!(itemElement && frameElement);
  }

  function isEditing() {
    return !!(overlayElement && overlayElement.classList && overlayElement.classList.contains('is-editing'));
  }

  function readLayoutStyle() {
    if (!findElements()) return null;
    return {
      left: itemElement.style.left,
      top: itemElement.style.top,
      width: itemElement.style.width,
      height: itemElement.style.height,
      zIndex: itemElement.style.zIndex,
    };
  }

  function sameLayoutStyle(first, second) {
    if (!first || !second) return false;
    return first.left === second.left && first.top === second.top && first.width === second.width &&
      first.height === second.height && first.zIndex === second.zIndex;
  }

  function restoreLayoutStyle() {
    if (!layoutStyle || !findElements()) return;
    itemElement.style.left = layoutStyle.left;
    itemElement.style.top = layoutStyle.top;
    itemElement.style.width = layoutStyle.width;
    itemElement.style.height = layoutStyle.height;
    itemElement.style.zIndex = layoutStyle.zIndex;
  }

  function frameRect() {
    if (!findElements()) return null;
    var rect = frameElement.getBoundingClientRect();
    return { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
  }

  function captureExpandedSize() {
    if (!findElements()) return;
    var rect = itemElement.getBoundingClientRect();
    if (!isEditing() && lastAppliedBounds && Math.abs(rect.width - lastAppliedBounds.width) < 1 && Math.abs(rect.height - lastAppliedBounds.height) < 1) return;
    if (rect.width > iconSize + 1 && rect.height > iconSize + 1) {
      expandedSize = { width: rect.width, height: rect.height };
    }
  }

  function anchorPixels(bounds) {
    if (!bounds) return null;
    if (!position) setAnchorFromItem(bounds, false);
    var maxX = Math.max(0, bounds.width - iconSize);
    var maxY = Math.max(0, bounds.height - iconSize);
    return { x: position.x * maxX, y: position.y * maxY, maxX: maxX, maxY: maxY };
  }

  function persistPosition() {
    if (!position) return;
    try { window.localStorage.setItem(positionKey, JSON.stringify(position)); } catch (e) {}
  }

  function setAnchor(x, y, bounds, shouldPersist) {
    if (!bounds) return;
    var maxX = Math.max(0, bounds.width - iconSize);
    var maxY = Math.max(0, bounds.height - iconSize);
    x = clamp(Number(x) || 0, 0, maxX);
    y = clamp(Number(y) || 0, 0, maxY);
    position = { x: maxX ? x / maxX : 0, y: maxY ? y / maxY : 0 };
    if (shouldPersist) persistPosition();
    return { x: x, y: y };
  }

  function setAnchorFromItem(bounds, shouldPersist) {
    if (!bounds || !findElements()) return null;
    var rect = itemElement.getBoundingClientRect();
    return setAnchor(rect.left - bounds.left, rect.top - bounds.top, bounds, shouldPersist);
  }

  function setItemBounds(x, y, width, height, collapsed) {
    if (!findElements()) return;
    itemElement.style.left = Math.round(x) + 'px';
    itemElement.style.top = Math.round(y) + 'px';
    itemElement.style.width = Math.round(width) + 'px';
    itemElement.style.height = Math.round(height) + 'px';
    itemElement.style.zIndex = collapsed ? '1000' : '';
    lastAppliedBounds = collapsed ? null : { width: Math.round(width), height: Math.round(height) };
    if (!collapsed) layoutStyle = readLayoutStyle();
  }

  function applyCollapsedPosition() {
    var bounds = frameRect();
    if (!bounds) return;
    var anchor = anchorPixels(bounds);
    if (anchor) setItemBounds(anchor.x, anchor.y, iconSize, iconSize, true);
  }

  function chooseAxis(anchor, iconExtent, frameExtent, panelExtent) {
    var roomAfter = frameExtent - anchor - iconExtent;
    var roomBefore = anchor;
    var result;
    if (roomAfter >= panelExtent) result = anchor;
    else if (roomBefore >= panelExtent) result = anchor + iconExtent - panelExtent;
    else if (roomAfter >= roomBefore) result = anchor;
    else result = anchor + iconExtent - panelExtent;
    return clamp(result, 0, Math.max(0, frameExtent - panelExtent));
  }

  function applyExpandedPosition() {
    var bounds = frameRect();
    if (!bounds) return;
    if (!expandedSize) return;
    var anchor = anchorPixels(bounds);
    if (!anchor) return;
    var width = Math.min(expandedSize.width, bounds.width);
    var height = Math.min(expandedSize.height, bounds.height);
    var x = chooseAxis(anchor.x, iconSize, bounds.width, width);
    var y = chooseAxis(anchor.y, iconSize, bounds.height, height);
    setItemBounds(x, y, width, height, false);
  }

  function initialise() {
    if (!findElements()) {
      if (!isDestroyed) window.setTimeout(initialise, 80);
      return;
    }
    layoutStyle = readLayoutStyle();
    wasEditing = isEditing();
    if (wasEditing) editStartStyle = layoutStyle;
    captureExpandedSize();
    if (appScope.collapsed && !wasEditing) {
      var bounds = frameRect();
      if (!position) setAnchorFromItem(bounds, true);
      applyCollapsedPosition();
    }
    isReady = true;
    if (typeof window.ResizeObserver === 'function') {
      resizeObserver = new window.ResizeObserver(function () {
        if (isEditing()) return;
        if (appScope.collapsed) applyCollapsedPosition();
        else captureExpandedSize();
      });
      resizeObserver.observe(itemElement);
    }
    if (overlayElement && typeof window.MutationObserver === 'function') {
      overlayObserver = new window.MutationObserver(onOverlayMutation);
      overlayObserver.observe(overlayElement, { attributes: true, attributeFilter: ['class'] });
      itemStyleObserver = new window.MutationObserver(onItemStyleMutation);
      itemStyleObserver.observe(itemElement, { attributes: true, attributeFilter: ['style'] });
    }
  }

  function onOverlayMutation() {
    schedule(function () {
      var editing = isEditing();
      if (editing === wasEditing) return;
      if (editing) {
        wasEditing = true;
        editStartStyle = layoutStyle || readLayoutStyle();
        restoreLayoutStyle();
        lastAppliedBounds = null;
        captureExpandedSize();
        return;
      }
      var currentStyle = readLayoutStyle();
      var layoutChanged = editStartStyle && !sameLayoutStyle(editStartStyle, currentStyle);
      layoutStyle = currentStyle;
      wasEditing = false;
      editStartStyle = null;
      lastAppliedBounds = null;
      if (appScope.collapsed) {
        if (layoutChanged) setAnchorFromItem(frameRect(), true);
        applyCollapsedPosition();
      } else {
        captureExpandedSize();
      }
    });
  }

  function onItemStyleMutation() {
    if (!isEditing()) return;
    layoutStyle = readLayoutStyle();
    captureExpandedSize();
  }

  function toggle() {
    if (suppressClick) {
      suppressClick = false;
      return false;
    }
    if (appScope.collapsed) {
      if (!position) setAnchorFromItem(frameRect(), true);
      expandedFromIcon = true;
      appScope.collapsed = false;
      schedule(applyExpandedPosition);
    } else {
      captureExpandedSize();
      if (!expandedFromIcon) setAnchorFromItem(frameRect(), true);
      expandedFromIcon = false;
      appScope.collapsed = true;
      schedule(applyCollapsedPosition);
    }
    return true;
  }

  function syncState() {
    if (!isReady) {
      schedule(initialise);
      return;
    }
    if (appScope.collapsed) {
      if (!position) setAnchorFromItem(frameRect(), true);
      schedule(applyCollapsedPosition);
    } else {
      expandedFromIcon = false;
      schedule(captureExpandedSize);
    }
  }

  function onPointerDown(event) {
    if (!appScope.collapsed || isEditing() || event.button !== 0) return;
    var target = event.target;
    if (!target || !target.closest || !target.closest(restoreSelector)) return;
    var bounds = frameRect();
    var anchor = anchorPixels(bounds);
    if (!anchor) return;
    drag = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      offsetX: event.clientX - bounds.left - anchor.x,
      offsetY: event.clientY - bounds.top - anchor.y,
      moved: false,
    };
    event.stopPropagation();
    if (target.setPointerCapture && event.pointerId !== undefined) {
      try { target.setPointerCapture(event.pointerId); } catch (e) {}
    }
  }

  function onPointerMove(event) {
    if (!drag || (drag.pointerId !== undefined && event.pointerId !== drag.pointerId)) return;
    var dx = event.clientX - drag.startX;
    var dy = event.clientY - drag.startY;
    if (!drag.moved && Math.sqrt(dx * dx + dy * dy) < 4) return;
    drag.moved = true;
    if (event.cancelable) event.preventDefault();
    var bounds = frameRect();
    if (!bounds) return;
    var anchor = setAnchor(event.clientX - bounds.left - drag.offsetX, event.clientY - bounds.top - drag.offsetY, bounds, false);
    if (anchor) setItemBounds(anchor.x, anchor.y, iconSize, iconSize, true);
  }

  function onPointerUp(event) {
    if (!drag || (drag.pointerId !== undefined && event.pointerId !== drag.pointerId)) return;
    if (drag.moved) {
      persistPosition();
      suppressClick = true;
      window.setTimeout(function () { suppressClick = false; }, 300);
    }
    drag = null;
  }

  function onResize() {
    if (isEditing()) return;
    if (appScope.collapsed) schedule(applyCollapsedPosition);
    else schedule(captureExpandedSize);
  }

  if (rootElement && rootElement.addEventListener) rootElement.addEventListener('pointerdown', onPointerDown, false);
  window.addEventListener('pointermove', onPointerMove, true);
  window.addEventListener('pointerup', onPointerUp, true);
  window.addEventListener('pointercancel', onPointerUp, true);
  window.addEventListener('resize', onResize);
  appElement.ready(function () { schedule(initialise); });

  return {
    toggle: toggle,
    syncState: syncState,
    destroy: function () {
      isDestroyed = true;
      if (rootElement && rootElement.removeEventListener) rootElement.removeEventListener('pointerdown', onPointerDown, false);
      window.removeEventListener('pointermove', onPointerMove, true);
      window.removeEventListener('pointerup', onPointerUp, true);
      window.removeEventListener('pointercancel', onPointerUp, true);
      window.removeEventListener('resize', onResize);
      if (resizeObserver) resizeObserver.disconnect();
      if (overlayObserver) overlayObserver.disconnect();
      if (itemStyleObserver) itemStyleObserver.disconnect();
    },
  };
}
