(function () {
  "use strict";

  var NAME_KEY = "desert-comments-name-v1";
  var TOKEN_KEY = "desert-comments-token-v1";
  var SEEN_KEY = "desert-comments-seen-replies-v1";

  function storageGet(key, fallback) {
    try {
      var value = localStorage.getItem(key);
      return value === null ? fallback : value;
    } catch (error) {
      return fallback;
    }
  }

  function storageSet(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch (error) {}
  }

  function randomHex(bytes) {
    var values = new Uint8Array(bytes);
    if (window.crypto && window.crypto.getRandomValues) {
      window.crypto.getRandomValues(values);
    } else {
      for (var i = 0; i < bytes; i += 1) {
        values[i] = Math.floor(Math.random() * 256);
      }
    }
    return Array.prototype.map.call(values, function (value) {
      return value.toString(16).padStart(2, "0");
    }).join("");
  }

  function ensureToken() {
    var token = storageGet(TOKEN_KEY, "");
    if (!/^[0-9a-fA-F]{32,128}$/.test(token)) {
      token = randomHex(32);
      storageSet(TOKEN_KEY, token);
    }
    return token;
  }

  function seenReplies() {
    try {
      var value = JSON.parse(storageGet(SEEN_KEY, "{}"));
      return value && typeof value === "object" ? value : {};
    } catch (error) {
      return {};
    }
  }

  function saveSeenReplies(map) {
    storageSet(SEEN_KEY, JSON.stringify(map));
  }

  function formatDate(comment) {
    if (!comment.created_iso) {
      return "";
    }
    var date = new Date(comment.created_iso);
    if (Number.isNaN(date.getTime())) {
      return "";
    }
    return date.toLocaleString(undefined, {
      month: "short",
      day: "numeric",
      year: "numeric",
      hour: "numeric",
      minute: "2-digit"
    });
  }

  function paragraphNodes(text) {
    var fragment = document.createDocumentFragment();
    String(text || "").split(/\n{2,}/).forEach(function (chunk) {
      var lines = chunk.split(/\n/);
      var paragraph = document.createElement("p");
      lines.forEach(function (line, index) {
        if (index) {
          paragraph.appendChild(document.createElement("br"));
        }
        paragraph.appendChild(document.createTextNode(line));
      });
      fragment.appendChild(paragraph);
    });
    return fragment;
  }

  function normalizedText(text) {
    return String(text || "").replace(/\r\n?/g, "\n").trim();
  }

  function hasMatchingComment(comments, text) {
    var expected = normalizedText(text);
    if (!expected || !Array.isArray(comments)) {
      return false;
    }
    return comments.some(function (comment) {
      return normalizedText(comment.body) === expected;
    });
  }

  function isNetworkError(error) {
    var message = String(error && error.message ? error.message : "");
    return error && (error.name === "TypeError" || /failed to fetch|network|load failed/i.test(message));
  }

  function setStatus(section, message, error) {
    var status = section.querySelector("[data-comments-status]");
    if (!status) {
      return;
    }
    status.textContent = message || "";
    status.hidden = !message;
    status.classList.toggle("is-error", Boolean(error));
  }

  function renderThread(section, comments) {
    var list = section.querySelector("[data-comments-list]");
    var count = section.querySelector("[data-comments-count]");
    if (!list) {
      return;
    }
    comments = Array.isArray(comments) ? comments : [];
    list.replaceChildren();
    if (count) {
      count.textContent = comments.length + " " + (comments.length === 1 ? "comment" : "comments");
    }
    if (!comments.length) {
      setStatus(section, "No comments yet. Start the conversation.", false);
      return;
    }
    setStatus(section, "", false);

    var byParent = {};
    comments.forEach(function (comment) {
      var parent = comment.parent_id || 0;
      if (!byParent[parent]) {
        byParent[parent] = [];
      }
      byParent[parent].push(comment);
    });

    function appendComment(comment, depth) {
      var article = document.createElement("article");
      article.className = "comment";
      article.id = "comment-" + comment.id;
      if (comment.parent_id) {
        article.classList.add("is-reply");
      }
      if (depth > 0) {
        article.style.marginLeft = Math.min(depth * 22, 66) + "px";
      }

      var meta = document.createElement("div");
      meta.className = "comment-meta";
      var author = document.createElement("strong");
      author.textContent = comment.author_name || "Anonymous";
      var time = document.createElement("time");
      time.dateTime = comment.created_iso || "";
      time.textContent = formatDate(comment);
      meta.append(author, time);

      var body = document.createElement("div");
      body.className = "comment-body";
      body.appendChild(paragraphNodes(comment.body));

      var actions = document.createElement("div");
      actions.className = "comment-actions";
      var reply = document.createElement("button");
      reply.type = "button";
      reply.textContent = "Reply";
      reply.addEventListener("click", function () {
        setReplyTarget(section, comment);
      });
      actions.appendChild(reply);

      article.append(meta, body, actions);
      list.appendChild(article);

      (byParent[comment.id] || []).forEach(function (child) {
        appendComment(child, depth + 1);
      });
    }

    (byParent[0] || []).forEach(function (comment) {
      appendComment(comment, 0);
    });
  }

  function setReplyTarget(section, comment) {
    var form = section.querySelector("[data-comment-form]");
    if (!form) {
      return;
    }
    form.elements.parent_id.value = comment.id;
    var cancel = section.querySelector("[data-comment-cancel]");
    if (cancel) {
      cancel.hidden = false;
    }
    setStatus(section, "Replying to " + (comment.author_name || "Anonymous") + ".", false);
    form.scrollIntoView({ behavior: "smooth", block: "center" });
    form.elements.body.focus();
  }

  function clearReplyTarget(section) {
    var form = section.querySelector("[data-comment-form]");
    if (form) {
      form.elements.parent_id.value = "";
    }
    var cancel = section.querySelector("[data-comment-cancel]");
    if (cancel) {
      cancel.hidden = true;
    }
    setStatus(section, "", false);
  }

  function loadThread(section, options) {
    options = options || {};
    var contentId = section.getAttribute("data-content-id");
    return fetch("/comments/thread?content_id=" + encodeURIComponent(contentId), {
      credentials: "same-origin",
      headers: { "Accept": "application/json" }
    }).then(function (response) {
      return response.json().then(function (payload) {
        if (!response.ok || !payload.ok) {
          throw new Error(payload.error || "Comments are unavailable.");
        }
        renderThread(section, payload.comments || []);
        return payload.comments || [];
      });
    }).catch(function (error) {
      if (!options.silent) {
        setStatus(section, error.message || "Comments are unavailable.", true);
      }
      if (options.reject) {
        throw error;
      }
      return [];
    });
  }

  function setRatingStatus(section, message, error) {
    var status = section.querySelector("[data-rating-status]");
    if (!status) {
      return;
    }
    status.textContent = message || "";
    status.hidden = !message;
    status.classList.toggle("is-error", Boolean(error));
  }

  function renderRating(section, payload) {
    var average = section.querySelector("[data-rating-average]");
    var count = Number(payload && payload.count ? payload.count : 0);
    var score = Number(payload && payload.average ? payload.average : 0);
    var viewer = Number(payload && payload.viewer_rating ? payload.viewer_rating : 0);
    var buttons = section.querySelectorAll("[data-rating-value]");

    if (average) {
      average.textContent = count ? score.toFixed(1) : "Rate";
    }
    setRatingStatus(
      section,
      count ? count + " " + (count === 1 ? "vote" : "votes") : "No votes",
      false
    );

    buttons.forEach(function (button) {
      var value = Number(button.getAttribute("data-rating-value") || 0);
      var selected = viewer && value <= viewer;
      button.classList.toggle("is-selected", Boolean(selected));
      button.setAttribute("aria-pressed", selected ? "true" : "false");
    });
  }

  function loadRating(section) {
    var contentId = section.getAttribute("data-content-id");
    return fetch("/ratings/summary?content_id=" + encodeURIComponent(contentId), {
      credentials: "same-origin",
      headers: { "Accept": "application/json" }
    }).then(function (response) {
      return response.json().then(function (payload) {
        if (!response.ok || !payload.ok) {
          throw new Error(payload.error || "Ratings are unavailable.");
        }
        renderRating(section, payload);
      });
    }).catch(function (error) {
      setRatingStatus(section, error.message || "Ratings are unavailable.", true);
    });
  }

  function bindRating(section) {
    section.querySelectorAll("[data-rating-value]").forEach(function (button) {
      button.addEventListener("click", function () {
        var body = new URLSearchParams();
        body.set("content_id", section.getAttribute("data-content-id"));
        body.set("rating", button.getAttribute("data-rating-value"));

        setRatingStatus(section, "Saving...", false);
        section.querySelectorAll("[data-rating-value]").forEach(function (item) {
          item.disabled = true;
        });

        fetch("/ratings/vote", {
          method: "POST",
          credentials: "same-origin",
          headers: {
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"
          },
          body: body.toString()
        }).then(function (response) {
          return response.json().then(function (payload) {
            if (!response.ok || !payload.ok) {
              throw new Error(payload.error || "Rating could not be saved.");
            }
            renderRating(section, payload);
            setRatingStatus(section, "Saved", false);
          });
        }).catch(function (error) {
          setRatingStatus(section, error.message || "Rating could not be saved.", true);
        }).finally(function () {
          section.querySelectorAll("[data-rating-value]").forEach(function (item) {
            item.disabled = false;
          });
        });
      });
    });
  }

  function renderNotifications(section, replies) {
    var box = section.querySelector("[data-comment-notifications]");
    if (!box) {
      return;
    }
    var seen = seenReplies();
    var unseen = (Array.isArray(replies) ? replies : []).filter(function (reply) {
      return !seen[String(reply.id)];
    });

    box.replaceChildren();
    if (!unseen.length) {
      box.hidden = true;
      return;
    }

    var heading = document.createElement("h3");
    heading.textContent = unseen.length === 1 ? "1 new reply" : unseen.length + " new replies";
    box.appendChild(heading);

    unseen.slice(0, 5).forEach(function (reply) {
      var item = document.createElement("div");
      item.className = "comment-reply-notice";
      var link = document.createElement("a");
      link.href = reply.post_url || "#comment-" + reply.id;
      link.textContent = reply.post_title || "Open reply";
      var excerpt = document.createElement("span");
      excerpt.textContent = (reply.author_name || "Anonymous") + ": " + String(reply.body || "").slice(0, 120);
      item.append(link, excerpt);
      box.appendChild(item);
    });

    var mark = document.createElement("button");
    mark.type = "button";
    mark.className = "comment-reply-mark";
    mark.textContent = "Mark seen";
    mark.addEventListener("click", function () {
      unseen.forEach(function (reply) {
        seen[String(reply.id)] = 1;
      });
      saveSeenReplies(seen);
      box.hidden = true;
    });
    box.appendChild(mark);
    box.hidden = false;
  }

  function loadNotifications(section) {
    var token = ensureToken();
    var body = new URLSearchParams();
    body.set("commenter_token", token);
    return fetch("/comments/notifications", {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"
      },
      body: body.toString()
    }).then(function (response) {
      return response.json();
    }).then(function (payload) {
      renderNotifications(section, payload.replies || []);
    }).catch(function () {});
  }

  function bindForm(section) {
    var form = section.querySelector("[data-comment-form]");
    var nameInput = section.querySelector("[data-comment-name]");
    var cancel = section.querySelector("[data-comment-cancel]");
    if (!form) {
      return;
    }
    if (nameInput) {
      nameInput.value = storageGet(NAME_KEY, "");
      nameInput.addEventListener("input", function () {
        storageSet(NAME_KEY, nameInput.value);
      });
    }
    if (cancel) {
      cancel.addEventListener("click", function () {
        clearReplyTarget(section);
      });
    }

    form.addEventListener("submit", function (event) {
      event.preventDefault();
      var submit = form.querySelector('button[type="submit"]');
      if (submit) {
        submit.disabled = true;
      }
      setStatus(section, "Posting comment...", false);
      var body = new URLSearchParams();
      body.set("content_id", form.elements.content_id.value);
      body.set("parent_id", form.elements.parent_id.value || "");
      body.set("author_name", form.elements.author_name.value || "");
      body.set("body", form.elements.body.value || "");
      body.set("website", form.elements.website.value || "");
      body.set("commenter_token", ensureToken());
      if (form.elements.author_name.value) {
        storageSet(NAME_KEY, form.elements.author_name.value);
      }

      fetch("/comments/create", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Accept": "application/json",
          "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"
        },
        body: body.toString()
      }).then(function (response) {
        return response.json().then(function (payload) {
          if (!response.ok || !payload.ok) {
            throw new Error(payload.error || "Comment could not be posted.");
          }
          if (payload.token) {
            storageSet(TOKEN_KEY, payload.token);
          }
          form.elements.body.value = "";
          clearReplyTarget(section);
          setStatus(section, "Comment posted.", false);
          return loadThread(section).then(function () {
            return loadNotifications(section);
          });
        });
      }).catch(function (error) {
        if (isNetworkError(error)) {
          var submittedBody = form.elements.body.value || "";
          setStatus(section, "Checking for your comment...", false);
          return loadThread(section, { silent: true, reject: true }).then(function (comments) {
            if (hasMatchingComment(comments, submittedBody)) {
              form.elements.body.value = "";
              clearReplyTarget(section);
              setStatus(section, "Comment posted.", false);
              return loadNotifications(section);
            }
            setStatus(section, "Connection interrupted. Refresh if the comment does not appear.", false);
          }).catch(function () {
            setStatus(section, "Connection interrupted. Refresh if the comment does not appear.", false);
          });
        }
        setStatus(section, error.message || "Comment could not be posted.", true);
      }).finally(function () {
        if (submit) {
          submit.disabled = false;
        }
      });
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    document.querySelectorAll("[data-rating]").forEach(function (section) {
      bindRating(section);
      loadRating(section);
    });
    document.querySelectorAll("[data-comments]").forEach(function (section) {
      ensureToken();
      bindForm(section);
      loadThread(section).then(function () {
        return loadNotifications(section);
      });
    });
  });
}());
