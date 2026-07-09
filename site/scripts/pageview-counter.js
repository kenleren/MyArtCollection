(function () {
  "use strict";

  var dnt = navigator.doNotTrack || window.doNotTrack || navigator.msDoNotTrack;
  if (dnt === "1" || dnt === "yes") {
    return;
  }

  function normalizedPath() {
    var path = window.location.pathname || "/";
    if (path !== "/" && !path.endsWith("/")) {
      path += "/";
    }
    return path;
  }

  function referrerCategory() {
    if (!document.referrer) {
      return "direct";
    }
    try {
      var referrer = new URL(document.referrer);
      return referrer.origin === window.location.origin ? "internal" : "external";
    } catch (_error) {
      return "direct";
    }
  }

  function screenBucket() {
    var width = window.innerWidth || 0;
    if (width <= 0) {
      return "unknown";
    }
    if (width < 640) {
      return "small";
    }
    if (width < 1024) {
      return "medium";
    }
    return "large";
  }

  var payload = JSON.stringify({
    path: normalizedPath(),
    referrerCategory: referrerCategory(),
    screenBucket: screenBucket(),
  });

  var endpoint = "/api/site/pageview";
  var blob = new Blob([payload], { type: "application/json" });

  if (navigator.sendBeacon && navigator.sendBeacon(endpoint, blob)) {
    return;
  }

  fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: payload,
    keepalive: true,
    credentials: "same-origin",
  }).catch(function () {
    // Counter failures must not affect the public site experience.
  });
})();
