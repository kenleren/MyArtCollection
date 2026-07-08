(function () {
  const form = document.querySelector("#beta-signup-form");
  const status = document.querySelector("#beta-signup-status");

  if (!form || !status) {
    return;
  }

  const loadedAt = Date.now();
  const submittedAtField = form.querySelector('input[name="submittedAtClientMs"]');
  if (submittedAtField) {
    submittedAtField.value = String(loadedAt);
  }

  function showStatus(kind, message) {
    status.hidden = false;
    status.textContent = message;
    status.dataset.kind = kind;
  }

  function value(name) {
    const field = form.elements.namedItem(name);
    return field && "value" in field ? field.value.trim() : "";
  }

  function selectedPlatform() {
    const field = form.querySelector('input[name="platform"]:checked');
    return field ? field.value : "";
  }

  form.addEventListener("submit", async function (event) {
    event.preventDefault();

    const email = value("email");
    const platform = selectedPlatform();
    const consent = form.querySelector("#beta-consent").checked;
    if (!email || !platform || !consent) {
      showStatus("error", "Please add your email, choose a platform, and confirm consent before submitting.");
      return;
    }

    const submitButton = form.querySelector('button[type="submit"]');
      if (submitButton) {
        submitButton.disabled = true;
      }

    try {
      const elapsedMs = Date.now() - loadedAt;
      if (elapsedMs < 2600) {
        await new Promise(function (resolve) {
          window.setTimeout(resolve, 2600 - elapsedMs);
        });
      }

      const response = await fetch(form.action, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email,
          name: value("name") || undefined,
          platform,
          country: value("country") || undefined,
          notes: value("notes") || undefined,
          consent,
          consentVersion: value("consentVersion"),
          retentionVersion: value("retentionVersion"),
          sourceRoute: value("sourceRoute"),
          submittedAtClientMs: Number(value("submittedAtClientMs")),
          website: value("website"),
        }),
      });

      if (!response.ok) {
        throw new Error("Request rejected");
      }

      form.reset();
      if (submittedAtField) {
        submittedAtField.value = String(Date.now());
      }
      showStatus(
        "success",
        "Thanks. Your request was queued for manual review. If there is a fit for the current beta, Archivale will contact you with separate tester instructions.",
      );
    } catch (error) {
      showStatus(
        "error",
        "We could not accept this request right now. Please try again later or contact support.",
      );
    } finally {
      if (submitButton) {
        submitButton.disabled = false;
      }
    }
  });
})();
