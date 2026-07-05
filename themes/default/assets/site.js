/* DesertCMS public shell v2. */
(function () {
  var root = document.documentElement;
  var configuredTheme = root.getAttribute("data-default-theme") || root.getAttribute("data-theme") || "light";
  var normalizedTheme = configuredTheme === "dark" ? "dark" : "light";

  root.classList.add("has-js");
  root.setAttribute("data-theme", normalizedTheme);

  function ready(callback) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", callback);
      return;
    }
    callback();
  }

  function collectAnalytics() {
    if (root.getAttribute("data-analytics-enabled") !== "1") {
      return;
    }
    if (navigator.doNotTrack === "1" || window.doNotTrack === "1") {
      return;
    }
    var params = new URLSearchParams();
    params.set("path", window.location.pathname || "/");
    params.set("referrer", document.referrer || "");
    var body = params.toString();
    if (navigator.sendBeacon) {
      navigator.sendBeacon("/analytics/collect", new Blob([body], { type: "application/x-www-form-urlencoded" }));
      return;
    }
    if (window.fetch) {
      fetch("/analytics/collect", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: body,
        credentials: "same-origin",
        keepalive: true
      }).catch(function () {});
    }
  }

  ready(function () {
    var button = document.querySelector("[data-theme-toggle]");
    var menuButton = document.querySelector("[data-site-menu-toggle]");
    var menu = document.querySelector("[data-site-menu]");
    var header = menuButton ? menuButton.closest(".site-header") : null;

    function setTheme(theme) {
      var next = theme === "dark" ? "dark" : "light";
      document.documentElement.setAttribute("data-theme", next);
      if (button) {
        button.setAttribute("data-theme-state", next);
        button.setAttribute("aria-label", next === "dark" ? "Switch to light mode" : "Switch to dark mode");
      }
    }

    setTheme(normalizedTheme);
    if (button) {
      button.addEventListener("click", function () {
        setTheme(document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark");
      });
    }

    function setMenu(open) {
      if (!menuButton || !header) {
        return;
      }
      header.classList.toggle("is-menu-open", open);
      menuButton.setAttribute("aria-expanded", open ? "true" : "false");
      menuButton.setAttribute("aria-label", open ? "Close navigation" : "Open navigation");
    }

    function normalizePath(path) {
      if (!path) {
        return "/";
      }
      return path.replace(/\/index\.html$/, "/").replace(/\/+$/, "/") || "/";
    }

    if (menu) {
      var current = normalizePath(window.location.pathname);
      Array.prototype.forEach.call(menu.querySelectorAll("a[href]"), function (link) {
        var href = link.getAttribute("href") || "";
        if (/^https?:\/\//i.test(href)) {
          return;
        }
        if (normalizePath(href.split("#")[0].split("?")[0]) === current) {
          link.setAttribute("aria-current", "page");
          link.classList.add("active");
        }
      });
    }

    if (menuButton) {
      menuButton.addEventListener("click", function () {
        setMenu(!(header && header.classList.contains("is-menu-open")));
      });
      if (menu) {
        menu.addEventListener("click", function (event) {
          if (event.target && event.target.closest("a")) {
            setMenu(false);
          }
        });
      }
      document.addEventListener("keydown", function (event) {
        if (event.key === "Escape") {
          setMenu(false);
        }
      });
      window.addEventListener("resize", function () {
        if (window.matchMedia("(min-width: 821px)").matches) {
          setMenu(false);
        }
      });
    }

    function updateCounter(field) {
      var container = field.closest ? field.closest(".public-count-field") : field.parentNode;
      var output = container ? container.querySelector("[data-counter-output]") : null;
      if (!output) {
        return;
      }
      var count = field.value.length;
      var min = parseInt(field.getAttribute("data-counter-min") || "0", 10);
      var max = parseInt(field.getAttribute("data-counter-max") || field.getAttribute("maxlength") || "0", 10);
      var text = max ? count + " / " + max + " characters" : count + " characters";
      if (min && count > 0 && count < min) {
        text += " (" + (min - count) + " more minimum)";
      }
      output.textContent = text;
      if (container) {
        container.classList.toggle("is-under-limit", !!(min && count > 0 && count < min));
        container.classList.toggle("is-over-limit", !!(max && count > max));
      }
    }

    function formatFileSize(bytes) {
      if (!bytes && bytes !== 0) {
        return "";
      }
      if (bytes >= 1048576) {
        return (bytes / 1048576).toFixed(1).replace(/\.0$/, "") + " MB";
      }
      if (bytes >= 1024) {
        return Math.ceil(bytes / 1024) + " KB";
      }
      return bytes + " bytes";
    }

    function updateUploadPreview(field) {
      var container = field.closest ? field.closest(".public-upload-field") : field.parentNode;
      var output = container ? container.querySelector("[data-upload-preview-output]") : null;
      if (!output) {
        return;
      }
      var file = field.files && field.files[0] ? field.files[0] : null;
      output.textContent = "";
      var thumb = document.createElement("span");
      thumb.className = "public-upload-thumb";
      thumb.setAttribute("aria-hidden", "true");
      var label = document.createElement("small");
      if (!file) {
        label.textContent = "No file selected";
        output.appendChild(thumb);
        output.appendChild(label);
        return;
      }
      label.textContent = file.name + " (" + formatFileSize(file.size) + ")";
      output.appendChild(thumb);
      output.appendChild(label);
      if (/^image\//.test(file.type || "") && window.FileReader) {
        var reader = new FileReader();
        reader.onload = function (event) {
          thumb.style.backgroundImage = "url(\"" + event.target.result + "\")";
          thumb.classList.add("has-image");
        };
        reader.readAsDataURL(file);
      }
    }

    Array.prototype.forEach.call(document.querySelectorAll("[data-character-counter]"), function (field) {
      updateCounter(field);
      field.addEventListener("input", function () { updateCounter(field); });
    });
    Array.prototype.forEach.call(document.querySelectorAll("[data-upload-preview]"), function (field) {
      updateUploadPreview(field);
      field.addEventListener("change", function () { updateUploadPreview(field); });
    });

    collectAnalytics();
  });
}());
