(function () {
  'use strict';

  var TILE_SIZE = 256;
  var MIN_ZOOM = 1;
  var MAX_ZOOM = 19;

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function project(lat, lng, zoom) {
    var scale = TILE_SIZE * Math.pow(2, zoom);
    var sin = Math.sin(clamp(lat, -85.05112878, 85.05112878) * Math.PI / 180);
    return {
      x: (lng + 180) / 360 * scale,
      y: (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * scale
    };
  }

  function unproject(x, y, zoom) {
    var scale = TILE_SIZE * Math.pow(2, zoom);
    var lng = x / scale * 360 - 180;
    var n = Math.PI - 2 * Math.PI * y / scale;
    var lat = 180 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)));
    return { lat: lat, lng: lng };
  }

  function tileUrl(template, z, x, y) {
    var max = Math.pow(2, z);
    var wrappedX = ((x % max) + max) % max;
    return String(template || '')
      .replace(/\{z\}/g, String(z))
      .replace(/\{x\}/g, String(wrappedX))
      .replace(/\{y\}/g, String(y));
  }

  function safeAttribution(html) {
    var wrapper = document.createElement('span');
    wrapper.innerHTML = String(html || '');
    Array.prototype.slice.call(wrapper.querySelectorAll('*')).forEach(function (node) {
      if (node.tagName !== 'A') {
        node.replaceWith(document.createTextNode(node.textContent || ''));
        return;
      }
      var href = node.getAttribute('href') || '';
      if (!/^https:\/\//i.test(href)) {
        node.replaceWith(document.createTextNode(node.textContent || ''));
        return;
      }
      node.setAttribute('target', '_blank');
      node.setAttribute('rel', 'noopener');
    });
    return wrapper.innerHTML;
  }

  function readConfig(container) {
    var script = container.querySelector('[data-map-config]');
    if (!script) {
      return {};
    }
    try {
      return JSON.parse(script.textContent || '{}') || {};
    } catch (error) {
      return {};
    }
  }

  function normalizePin(pin) {
    if (!pin) {
      return null;
    }
    var lat = Number(pin.lat);
    var lng = Number(pin.lng);
    if (!isFinite(lat) || !isFinite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      return null;
    }
    return {
      id: pin.id || '',
      title: pin.title || 'Untitled',
      label: pin.label || pin.title || 'Location',
      excerpt: pin.excerpt || '',
      image: /^\/assets\/media\/[0-9a-f]{64}\.jpg$/i.test(pin.image || '') ? pin.image : '',
      url: pin.url || '',
      type: pin.type || '',
      kind: pin.kind || 'other',
      kind_label: pin.kind_label || 'Location',
      lat: lat,
      lng: lng
    };
  }

  function normalizePins(pins) {
    return (Array.isArray(pins) ? pins : []).map(normalizePin).filter(Boolean);
  }

  function create(container, options) {
    var config = options || readConfig(container);
    var layers = config.layers || {};
    var defaultLayer = config.default_layer === 'satellite' ? 'satellite' : 'street';
    if (!layers[defaultLayer] || !layers[defaultLayer].url) {
      defaultLayer = layers.street && layers.street.url ? 'street' : 'satellite';
    }
    var state = {
      lat: Number(config.center && config.center.lat) || 34.5,
      lng: Number(config.center && config.center.lng) || -112,
      zoom: clamp(parseInt(config.zoom, 10) || 5, MIN_ZOOM, MAX_ZOOM),
      layer: defaultLayer,
      pins: normalizePins(config.pins),
      selected: null,
      dragging: false,
      dragStart: null,
      dragCenter: null
    };

    container.classList.add('slippy-map');
    container.innerHTML = [
      '<div class="slippy-map-toolbar">',
      '<div class="slippy-map-layer-tabs" role="group" aria-label="Map layer">',
      '<button type="button" data-map-layer="street">Map</button>',
      '<button type="button" data-map-layer="satellite">Satellite</button>',
      '</div>',
      '<div class="slippy-map-zoom" role="group" aria-label="Map zoom">',
      '<button type="button" data-map-zoom="in" aria-label="Zoom in">+</button>',
      '<button type="button" data-map-zoom="out" aria-label="Zoom out">-</button>',
      '</div>',
      '</div>',
      '<div class="slippy-map-stage" tabindex="0">',
      '<div class="slippy-map-tiles"></div>',
      '<div class="slippy-map-markers"></div>',
      '<div class="slippy-map-crosshair" aria-hidden="true"></div>',
      '</div>',
      '<div class="slippy-map-attribution"></div>'
    ].join('');

    var stage = container.querySelector('.slippy-map-stage');
    var tileLayer = container.querySelector('.slippy-map-tiles');
    var markerLayer = container.querySelector('.slippy-map-markers');
    var attribution = container.querySelector('.slippy-map-attribution');
    var layerButtons = container.querySelectorAll('[data-map-layer]');
    var changeCallback = typeof config.onChange === 'function' ? config.onChange : null;

    function activeLayer() {
      return layers[state.layer] || layers.street || layers.satellite || {};
    }

    function size() {
      var rect = stage.getBoundingClientRect();
      return {
        width: Math.max(280, Math.round(rect.width || container.clientWidth || 640)),
        height: Math.max(260, Math.round(rect.height || 420))
      };
    }

    function setCenter(lat, lng) {
      state.lat = clamp(Number(lat) || 0, -85.05112878, 85.05112878);
      state.lng = clamp(Number(lng) || 0, -180, 180);
    }

    function setZoom(zoom, aroundPoint) {
      var nextZoom = clamp(parseInt(zoom, 10), MIN_ZOOM, MAX_ZOOM);
      if (nextZoom === state.zoom) {
        return;
      }
      if (aroundPoint) {
        var currentSize = size();
        var center = project(state.lat, state.lng, state.zoom);
        var before = unproject(
          center.x + aroundPoint.x - currentSize.width / 2,
          center.y + aroundPoint.y - currentSize.height / 2,
          state.zoom
        );
        state.zoom = nextZoom;
        var afterCenter = project(before.lat, before.lng, state.zoom);
        var newCenter = unproject(
          afterCenter.x - aroundPoint.x + currentSize.width / 2,
          afterCenter.y - aroundPoint.y + currentSize.height / 2,
          state.zoom
        );
        setCenter(newCenter.lat, newCenter.lng);
      } else {
        state.zoom = nextZoom;
      }
      render();
    }

    function pinPoint(pin) {
      var mapSize = size();
      var center = project(state.lat, state.lng, state.zoom);
      var point = project(pin.lat, pin.lng, state.zoom);
      return {
        x: point.x - center.x + mapSize.width / 2,
        y: point.y - center.y + mapSize.height / 2
      };
    }

    function renderTiles() {
      var layer = activeLayer();
      tileLayer.innerHTML = '';
      if (!layer.url) {
        tileLayer.innerHTML = '<div class="map-empty">No tile layer configured.</div>';
        return;
      }
      var mapSize = size();
      var center = project(state.lat, state.lng, state.zoom);
      var left = center.x - mapSize.width / 2;
      var top = center.y - mapSize.height / 2;
      var minX = Math.floor(left / TILE_SIZE) - 1;
      var maxX = Math.floor((left + mapSize.width) / TILE_SIZE) + 1;
      var minY = Math.floor(top / TILE_SIZE) - 1;
      var maxY = Math.floor((top + mapSize.height) / TILE_SIZE) + 1;
      var maxTile = Math.pow(2, state.zoom);
      var fragment = document.createDocumentFragment();
      for (var x = minX; x <= maxX; x++) {
        for (var y = minY; y <= maxY; y++) {
          if (y < 0 || y >= maxTile) {
            continue;
          }
          var img = document.createElement('img');
          img.className = 'slippy-map-tile';
          img.alt = '';
          img.draggable = false;
          img.loading = 'lazy';
          img.src = tileUrl(layer.url, state.zoom, x, y);
          img.style.left = Math.round(x * TILE_SIZE - left) + 'px';
          img.style.top = Math.round(y * TILE_SIZE - top) + 'px';
          fragment.appendChild(img);
        }
      }
      tileLayer.appendChild(fragment);
    }

    function popupHtml(pin) {
      var title = escapeHtml(pin.title);
      var label = escapeHtml(pin.label);
      var kind = pin.kind_label ? '<small>' + escapeHtml(pin.kind_label) + '</small>' : '';
      var excerpt = pin.excerpt ? '<p>' + escapeHtml(pin.excerpt) + '</p>' : '';
      var link = pin.url ? '<a href="' + escapeHtml(pin.url) + '">Open item</a>' : '';
      var image = pin.image ? '<img class="map-popup-media" src="' + escapeHtml(pin.image) + '" alt="' + title + '" loading="lazy">' : '';
      return '<div class="map-popup">' + image + '<strong>' + title + '</strong>' + kind + '<span>' + label + '</span>' + excerpt + link + '</div>';
    }

    function renderMarkers() {
      markerLayer.innerHTML = '';
      if (!state.pins.length) {
        if (!config.picker) {
          markerLayer.innerHTML = '<div class="map-empty map-empty--pins">No mapped locations yet.</div>';
        }
        return;
      }
      var mapSize = size();
      var buckets = {};
      state.pins.forEach(function (pin) {
        var point = pinPoint(pin);
        if (point.x < -60 || point.y < -60 || point.x > mapSize.width + 60 || point.y > mapSize.height + 60) {
          return;
        }
        var key = Math.floor(point.x / 46) + ':' + Math.floor(point.y / 46);
        if (!buckets[key]) {
          buckets[key] = { pins: [], x: 0, y: 0 };
        }
        buckets[key].pins.push(pin);
        buckets[key].x += point.x;
        buckets[key].y += point.y;
      });
      Object.keys(buckets).forEach(function (key) {
        var bucket = buckets[key];
        var count = bucket.pins.length;
        var x = bucket.x / count;
        var y = bucket.y / count;
        var button = document.createElement('button');
        button.type = 'button';
        button.className = count > 1 ? 'map-cluster' : 'map-pin';
        button.style.left = Math.round(x) + 'px';
        button.style.top = Math.round(y) + 'px';
        button.textContent = count > 1 ? String(count) : '';
        button.setAttribute('aria-label', count > 1 ? count + ' locations in this area' : bucket.pins[0].title);
        button.addEventListener('click', function (event) {
          event.stopPropagation();
          if (count > 1) {
            var avgLat = bucket.pins.reduce(function (sum, pin) { return sum + pin.lat; }, 0) / count;
            var avgLng = bucket.pins.reduce(function (sum, pin) { return sum + pin.lng; }, 0) / count;
            setCenter(avgLat, avgLng);
            setZoom(state.zoom + 2);
            return;
          }
          state.selected = bucket.pins[0];
          renderMarkers();
        });
        markerLayer.appendChild(button);
      });
      if (state.selected) {
        var selectedPoint = pinPoint(state.selected);
        var popup = document.createElement('div');
        popup.className = 'map-popup-wrap';
        popup.style.left = Math.round(selectedPoint.x) + 'px';
        popup.style.top = Math.round(selectedPoint.y) + 'px';
        popup.innerHTML = popupHtml(state.selected);
        markerLayer.appendChild(popup);
      }
    }

    function renderControls() {
      Array.prototype.forEach.call(layerButtons, function (button) {
        var layerId = button.getAttribute('data-map-layer');
        var layer = layers[layerId] || {};
        button.hidden = !layer.url;
        button.classList.toggle('is-active', layerId === state.layer);
        button.setAttribute('aria-pressed', layerId === state.layer ? 'true' : 'false');
      });
      attribution.innerHTML = safeAttribution(activeLayer().attribution || '');
      container.classList.toggle('is-picker', !!config.picker);
    }

    function render() {
      renderControls();
      renderTiles();
      renderMarkers();
    }

    function fitPins() {
      if (!state.pins.length) {
        return;
      }
      if (state.pins.length === 1) {
        setCenter(state.pins[0].lat, state.pins[0].lng);
        state.zoom = Math.max(state.zoom, 8);
        return;
      }
      var mapSize = size();
      for (var zoom = MAX_ZOOM; zoom >= MIN_ZOOM; zoom--) {
        var xs = [];
        var ys = [];
        state.pins.forEach(function (pin) {
          var point = project(pin.lat, pin.lng, zoom);
          xs.push(point.x);
          ys.push(point.y);
        });
        var minX = Math.min.apply(Math, xs);
        var maxX = Math.max.apply(Math, xs);
        var minY = Math.min.apply(Math, ys);
        var maxY = Math.max.apply(Math, ys);
        if ((maxX - minX) <= mapSize.width - 90 && (maxY - minY) <= mapSize.height - 90) {
          state.zoom = zoom;
          var center = unproject((minX + maxX) / 2, (minY + maxY) / 2, zoom);
          setCenter(center.lat, center.lng);
          return;
        }
      }
    }

    Array.prototype.forEach.call(layerButtons, function (button) {
      button.addEventListener('click', function () {
        var layerId = button.getAttribute('data-map-layer');
        if (layers[layerId] && layers[layerId].url) {
          state.layer = layerId;
          render();
        }
      });
    });

    container.querySelector('[data-map-zoom="in"]').addEventListener('click', function () {
      setZoom(state.zoom + 1);
    });
    container.querySelector('[data-map-zoom="out"]').addEventListener('click', function () {
      setZoom(state.zoom - 1);
    });

    stage.addEventListener('mousedown', function (event) {
      state.dragging = true;
      state.dragStart = { x: event.clientX, y: event.clientY };
      state.dragCenter = project(state.lat, state.lng, state.zoom);
      stage.classList.add('is-dragging');
    });
    window.addEventListener('mouseup', function () {
      state.dragging = false;
      stage.classList.remove('is-dragging');
    });
    window.addEventListener('mousemove', function (event) {
      if (!state.dragging || !state.dragStart || !state.dragCenter) {
        return;
      }
      var next = unproject(
        state.dragCenter.x - (event.clientX - state.dragStart.x),
        state.dragCenter.y - (event.clientY - state.dragStart.y),
        state.zoom
      );
      setCenter(next.lat, next.lng);
      render();
    });
    stage.addEventListener('wheel', function (event) {
      event.preventDefault();
      var rect = stage.getBoundingClientRect();
      setZoom(state.zoom + (event.deltaY < 0 ? 1 : -1), {
        x: event.clientX - rect.left,
        y: event.clientY - rect.top
      });
    }, { passive: false });
    stage.addEventListener('click', function (event) {
      if (state.dragStart && (Math.abs(event.clientX - state.dragStart.x) > 4 || Math.abs(event.clientY - state.dragStart.y) > 4)) {
        return;
      }
      state.selected = null;
      if (config.picker) {
        var rect = stage.getBoundingClientRect();
        var mapSize = size();
        var center = project(state.lat, state.lng, state.zoom);
        var point = unproject(
          center.x + event.clientX - rect.left - mapSize.width / 2,
          center.y + event.clientY - rect.top - mapSize.height / 2,
          state.zoom
        );
        state.pins = [normalizePin({ lat: point.lat, lng: point.lng, title: 'Selected location', label: 'Selected location' })];
        setCenter(point.lat, point.lng);
        if (changeCallback) {
          changeCallback({ lat: point.lat, lng: point.lng });
        }
      }
      render();
    });
    window.addEventListener('resize', render);

    if (config.fit_pins && state.pins.length) {
      fitPins();
    }
    render();

    if (config.pins_url) {
      fetch(config.pins_url, { credentials: 'same-origin' })
        .then(function (response) { return response.ok ? response.json() : { pins: [] }; })
        .then(function (data) {
          state.pins = normalizePins(data.pins || []);
          if (config.fit_pins) {
            fitPins();
          }
          render();
        })
        .catch(function () {
          render();
        });
    }

    return {
      setPins: function (pins) {
        state.pins = normalizePins(pins);
        render();
      },
      setView: function (lat, lng, zoom) {
        setCenter(lat, lng);
        if (zoom) {
          state.zoom = clamp(parseInt(zoom, 10), MIN_ZOOM, MAX_ZOOM);
        }
        render();
      },
      invalidateSize: render
    };
  }

  window.DesertMap = { create: create };

  document.addEventListener('DOMContentLoaded', function () {
    Array.prototype.forEach.call(document.querySelectorAll('[data-desert-map]'), function (container) {
      create(container);
    });
  });
}());
