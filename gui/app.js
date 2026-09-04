// ==============================================================================
// FedUpDate - Frontend Controller & IPC Bridge
// ==============================================================================

const API_BASE = (window.location.protocol.startsWith('http') && window.location.port) ? window.location.origin : 'http://localhost:58100';

const state = {
  activePage: 'dashboard',
  scanData: null,
  packages: [],
  config: null,
  logs: [],
  ledger: [],
  isExecuting: false,
  clearedLevels: {},
  lastLogSig: ''
};

// Signal native host that UI has rendered
function signalAppReady() {
  if (window.chrome && window.chrome.webview) {
    try {
      // Sent directly, not from an animation frame. The host keeps this view
      // hidden until it receives this message, and a view that is not being
      // rendered is not given animation frames, so waiting for one here meant
      // the message was never sent and the splash only ever left on its
      // timeout. Waiting for a paint is pointless in any case: what the host
      // is waiting to hear is that the first audit finished.
      window.chrome.webview.postMessage('app_ready');
    } catch {}
  }
}

// In-application dialogs
//
// The browser's confirm and alert are drawn by the host as a system window
// titled with the local address the interface is served from. It cannot be
// styled, it does not follow the theme, and it names an implementation detail
// at the user. These resolve the same way without leaving the application:
// fedConfirm resolves true or false, fedNotify resolves when acknowledged.
function fedDialog({ title, body, note, confirmText, cancelText, danger }) {
  return new Promise((resolve) => {
    const overlay = document.getElementById('appDialog');
    const titleEl = document.getElementById('appDialogTitle');
    const bodyEl = document.getElementById('appDialogBody');
    const noteEl = document.getElementById('appDialogNote');
    const okBtn = document.getElementById('appDialogConfirm');
    const cancelBtn = document.getElementById('appDialogCancel');

    // Without the markup there is nothing to ask through, so a question
    // resolves as declined rather than silently acting.
    if (!overlay || !okBtn) { resolve(!cancelText); return; }

    if (titleEl) titleEl.textContent = title || 'FedUpDate';
    if (bodyEl) bodyEl.textContent = body || '';
    if (noteEl) {
      noteEl.textContent = note || '';
      noteEl.classList.toggle('hidden', !note);
    }

    okBtn.textContent = confirmText || 'OK';
    okBtn.className = `btn ${danger ? 'btn-danger' : 'btn-primary'}`;
    cancelBtn.textContent = cancelText || 'Cancel';
    cancelBtn.classList.toggle('hidden', !cancelText);

    const close = (result) => {
      overlay.classList.add('hidden');
      document.removeEventListener('keydown', onKey);
      okBtn.onclick = null;
      cancelBtn.onclick = null;
      overlay.onclick = null;
      resolve(result);
    };

    const onKey = (e) => {
      if (e.key === 'Escape') close(false);
      else if (e.key === 'Enter') close(true);
    };

    okBtn.onclick = () => close(true);
    cancelBtn.onclick = () => close(false);
    // Clicking away is a decline, and only when the backdrop itself is hit
    // rather than anything inside the card.
    overlay.onclick = (e) => { if (e.target === overlay) close(false); };
    document.addEventListener('keydown', onKey);

    overlay.classList.remove('hidden');
    okBtn.focus();
  });
}

function fedConfirm(body, opts = {}) {
  return fedDialog({ cancelText: 'Cancel', confirmText: 'Continue', ...opts, body });
}

function fedNotify(body, opts = {}) {
  return fedDialog({ ...opts, body, cancelText: null });
}

// Initialize Application
document.addEventListener('DOMContentLoaded', async () => {
  try {
    setupNavigation();
  } catch (e) { console.warn("Navigation setup:", e); }
  try {
    setupTheme();
  } catch (e) { console.warn("Theme setup:", e); }
  try {
    setupEventListeners();
  } catch (e) { console.warn("Event listeners setup:", e); }
  try {
    startLogPolling();
  } catch (e) { console.warn("Log polling setup:", e); }
  try {
    await loadVersionInfo();
  } catch (e) { console.warn("Version check:", e); }

  try {
    await loadInitialData();
  } catch (err) {
    console.warn("Initialization error:", err);
  } finally {
    signalAppReady();
  }
});

// There is deliberately no 'load' listener here. 'load' fires once the page's
// resources are in, which is long before the initial audit above has finished,
// and signalling there dismissed the branding splash within a frame of the
// window appearing. The host has its own ceiling for the case where this
// message never arrives.

// Setup Navigation
function setupNavigation() {
  const tabButtons = document.querySelectorAll('.nav-item[data-page]');

  window.navigateTo = function(pageId) {
    if (!pageId) return;
    state.activePage = pageId;

    // Update active state on tab buttons
    tabButtons.forEach(btn => {
      btn.classList.toggle('active', btn.dataset.page === pageId);
    });

    // Switch visible page view
    document.querySelectorAll('.page').forEach(page => {
      page.classList.toggle('active', page.id === `page-${pageId}`);
    });

    // Close notification flyout if open
    document.getElementById('notifFlyout')?.classList.add('hidden');

    // The version corner belongs to Settings only, so it does not float over
    // the other pages. Its popover closes with the page.
    document.getElementById('versionCorner')?.classList.toggle('hidden', pageId !== 'settings');
    document.getElementById('versionFlyout')?.classList.add('hidden');
  };

  tabButtons.forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      window.navigateTo(btn.dataset.page);
    });
  });

  // Toggle Navigation Sidebar Expansion (stays on current tab without navigation)
  const navRail = document.getElementById('navRail');
  const navToggleBtn = document.getElementById('navToggleBtn');
  if (navToggleBtn && navRail) {
    navToggleBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const isExpanded = navRail.classList.toggle('expanded');
      // The glyph carries the meaning, so the state is exposed to assistive
      // technology rather than spelled out next to it.
      navToggleBtn.setAttribute('aria-expanded', String(isExpanded));
      const toggleLabel = isExpanded ? 'Collapse navigation' : 'Expand navigation';
      navToggleBtn.dataset.tip = toggleLabel;
      navToggleBtn.setAttribute('aria-label', toggleLabel);
    });
  }

  setupNavTooltips(navRail);
}

// A collapsed rail is glyphs and nothing else, so every destination loses its
// name at the moment the name is needed most. The browser's own title tooltip
// waits about a second, is drawn by the operating system rather than by this
// design system, and cannot be placed against the rail. The name is served from
// the design system instead, and the title attribute retires into aria-label so
// assistive technology keeps it and no native tooltip appears over this one.
function setupNavTooltips(navRail) {
  if (!navRail) return;

  const tip = document.createElement('div');
  tip.className = 'nav-tooltip';
  tip.setAttribute('role', 'presentation');
  document.body.appendChild(tip);

  const rootFontSize = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
  const hide = () => tip.classList.remove('visible');

  const show = (el) => {
    // Expanded, the label is already on screen and a tooltip would only repeat it.
    if (navRail.classList.contains('expanded') || !el.dataset.tip) return;
    const rect = el.getBoundingClientRect();
    tip.textContent = el.dataset.tip;
    // The rail clips its own overflow so the label can unfurl without spilling,
    // which clips anything anchored inside a row too. The tip is positioned
    // against the viewport to escape that, and in rem so it tracks text scaling.
    tip.style.setProperty('--nav-tip-top', `${(rect.top + rect.height / 2) / rootFontSize}rem`);
    tip.style.setProperty('--nav-tip-left', `${rect.right / rootFontSize}rem`);
    tip.classList.add('visible');
  };

  navRail.querySelectorAll('.nav-item, .nav-toggle-btn').forEach(el => {
    const label = el.getAttribute('title')
      || el.querySelector('.nav-label')?.textContent?.trim()
      || el.getAttribute('aria-label');
    if (label) {
      el.dataset.tip = label;
      el.setAttribute('aria-label', label);
      el.removeAttribute('title');
    }
    el.addEventListener('mouseenter', () => show(el));
    el.addEventListener('focus', () => show(el));
    el.addEventListener('mouseleave', hide);
    el.addEventListener('blur', hide);
    el.addEventListener('click', hide);
  });

  navRail.addEventListener('mouseleave', hide);
  window.addEventListener('resize', hide);
  window.addEventListener('scroll', hide, true);
}

// Setup Theme Switcher with Windows OS Auto-Detection
function setupTheme() {
  const themeBtn = document.getElementById('themeToggleBtn');
  const themeSelect = document.getElementById('themeSelect');
  const html = document.documentElement;

  window.applyTheme = function(themeName) {
    const isDark = themeName === 'dark';
    html.dataset.theme = themeName;
    html.style.colorScheme = isDark ? 'dark' : 'light';

    // Synchronize browser/app window frame titlebar color
    const metaTheme = document.getElementById('themeColorMeta');
    const metaLight = document.getElementById('themeColorMetaLight');
    const metaDark = document.getElementById('themeColorMetaDark');
    const color = isDark ? '#141622' : '#f8fafc';
    if (metaTheme) metaTheme.setAttribute('content', color);
    if (metaLight) metaLight.setAttribute('content', color);
    if (metaDark) metaDark.setAttribute('content', color);

    if (themeSelect) {
      themeSelect.value = isDark ? 'Dark' : 'Light';
    }

    // Dynamic Theme Icon (Moon for Dark / Sun for Light)
    const themeIcon = document.getElementById('themeIcon');
    if (themeIcon) {
      if (isDark) {
        themeIcon.innerHTML = `<path d="M7.5 2a.75.75 0 0 1 .74.65 6.5 6.5 0 0 0 9.11 9.11.75.75 0 0 1 .9 1A8 8 0 1 1 6.75 2.25.75.75 0 0 1 7.5 2Z"/>`;
      } else {
        themeIcon.innerHTML = `<path d="M10 3a1 1 0 0 1 1 1v1a1 1 0 1 1-2 0V4a1 1 0 0 1 1-1Zm5.66 2.93a1 1 0 0 1 0 1.41l-.71.71a1 1 0 1 1-1.41-1.41l.7-.71a1 1 0 0 1 1.42 0ZM17 10a1 1 0 0 1-1 1h-1a1 1 0 1 1 0-2h1a1 1 0 0 1 1 1Zm-2.05 4.95a1 1 0 0 1-1.41 1.41l-.71-.7a1 1 0 0 1 1.41-1.42l.71.71ZM10 17a1 1 0 0 1-1-1v-1a1 1 0 1 1 2 0v1a1 1 0 0 1-1 1Zm-4.95-2.05a1 1 0 0 1-1.41-1.41l.7-.71a1 1 0 1 1 1.42 1.41l-.71.71ZM3 10a1 1 0 0 1 1-1h1a1 1 0 1 1 0 2H4a1 1 0 0 1-1-1Zm2.05-4.95a1 1 0 0 1 1.41-1.41l.71.7a1 1 0 1 1-1.41 1.42l-.71-.71ZM10 6a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z"/>`;
      }
    }

    // Direct Windows DWM native window frame painter call
    try {
      if (window.chrome && window.chrome.webview) {
        window.chrome.webview.postMessage(JSON.stringify({ action: 'theme', theme: themeName }));
      }
      fetch(`${API_BASE}/api/theme`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ theme: themeName })
      }).catch(() => {});
    } catch {}
  };

  // 1. Check OS Default Theme on startup
  const osPrefersLight = window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches;
  const initialTheme = osPrefersLight ? 'light' : 'dark';
  applyTheme(initialTheme);

  // 2. Listen for Windows OS Theme change in real-time
  if (window.matchMedia) {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
      if (!state.config?.general?.theme || state.config.general.theme === 'System') {
        applyTheme(e.matches ? 'dark' : 'light');
      }
    });
  }

  // 3. User toggle button in Titlebar
  if (themeBtn) {
    themeBtn.addEventListener('click', () => {
      const nextTheme = html.dataset.theme === 'dark' ? 'light' : 'dark';
      applyTheme(nextTheme);
    });
  }

  // 4. Preferences dropdown
  if (themeSelect) {
    themeSelect.addEventListener('change', (e) => {
      const val = e.target.value;
      if (val === 'System') {
        const sysLight = window.matchMedia('(prefers-color-scheme: light)').matches;
        applyTheme(sysLight ? 'light' : 'dark');
      } else {
        applyTheme(val.toLowerCase() === 'light' ? 'light' : 'dark');
      }
    });
  }
}

// Event Listeners
function setupEventListeners() {
  // Window Caption Controls
  const minBtn = document.getElementById('winMinBtn');
  const maxBtn = document.getElementById('winMaxBtn');
  const closeBtn = document.getElementById('winCloseBtn');

  function sendWindowAction(action) {
    if (window.chrome && window.chrome.webview) {
      window.chrome.webview.postMessage(action);
    } else {
      fetch(`${API_BASE}/api/window/${action}`).catch(() => {});
    }
  }

  if (minBtn) minBtn.addEventListener('click', () => sendWindowAction('min'));
  if (maxBtn) maxBtn.addEventListener('click', () => sendWindowAction('max'));
  if (closeBtn) closeBtn.addEventListener('click', () => sendWindowAction('close'));

  // Titlebar dragging for native borderless window
  const titlebar = document.getElementById('appTitleBar');
  if (titlebar) {
    // What counts as furniture rather than content. A press on furniture moves
    // the window; a press on anything listed here does not. The notification
    // panel is inside the title bar, so without naming it a press on a
    // notification dragged the whole window instead of selecting the text, and
    // a double click maximised it.
    const notDraggable = 'button, input, select, a, .window-caption-controls, .notif-flyout';

    titlebar.addEventListener('mousedown', (e) => {
      if (e.target.closest(notDraggable)) return;
      if (e.button === 0) {
        sendWindowAction('drag');
      }
    });
    // Double click titlebar to toggle maximize
    titlebar.addEventListener('dblclick', (e) => {
      if (e.target.closest(notDraggable)) return;
      sendWindowAction('max');
    });
  }

  // Main Action Buttons (Update All / WhatIf)
  document.getElementById('runSuperUpdateBtn')?.addEventListener('click', () => executeTargetUpdate({ all: true, isWhatIf: false }));
  document.getElementById('whatIfBtn')?.addEventListener('click', () => executeTargetUpdate({ all: true, isWhatIf: true }));

  // Direct Target Engine Actions
  document.getElementById('btnUpdateOSDirect')?.addEventListener('click', () => executeTargetUpdate({ os: true }));
  document.getElementById('installAllOSUpdatesBtn')?.addEventListener('click', () => executeTargetUpdate({ os: true }));
  document.getElementById('rescanOSUpdatesBtn')?.addEventListener('click', () => triggerScan({ offerElevation: true }));

  document.getElementById('btnUpdateWingetDirect')?.addEventListener('click', () => executeTargetUpdate({ winget: true }));
  document.getElementById('btnSyncStoreDirect')?.addEventListener('click', () => executeTargetUpdate({ store: true }));
  document.getElementById('triggerStoreSyncBtn')?.addEventListener('click', () => executeTargetUpdate({ store: true }));

  // Notification Center Bell & Flyout
  const notifBellBtn = document.getElementById('notifBellBtn');
  const notifFlyout = document.getElementById('notifFlyout');
  if (notifBellBtn && notifFlyout) {
    notifBellBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      notifFlyout.classList.toggle('hidden');
    });

    document.addEventListener('click', (e) => {
      if (!e.target.closest('#notifWrapper')) {
        notifFlyout.classList.add('hidden');
      }
    });

  const versionGlyphBtn = document.getElementById('versionGlyphBtn');
  if (versionGlyphBtn) {
    versionGlyphBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      toggleVersionFlyout();
    });

    document.addEventListener('click', (e) => {
      if (!e.target.closest('#versionCorner')) {
        document.getElementById('versionFlyout')?.classList.add('hidden');
      }
    });
  }

  // Changing channel changes which releases this installation is offered, so it
  // is saved on its own rather than waiting for the Save button, and the check
  // is re-run against the new channel immediately. The POST forces the server
  // to drop its cached answer, which was taken for the previous channel.
  document.getElementById('updateChannelSelect')?.addEventListener('change', async (e) => {
    const channel = e.target.value === 'beta' ? 'beta' : 'stable';
    const badge = document.getElementById('updateChannelBadge');
    if (badge) badge.textContent = channel === 'beta' ? 'Beta' : 'Stable';

    try {
      await fetch(`${API_BASE}/api/config`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ updateChannel: channel })
      });
      await fetch(`${API_BASE}/api/version`, { method: 'POST' });
      await fetch(`${API_BASE}/api/changelog`, { method: 'POST' });
      await loadVersionInfo();
      setDockProgress("Saved", `Update channel set to ${channel}.`, 100, false);
    } catch (err) {
      setDockProgress("Error", `Could not change channel: ${err.message}`, 0, false);
    }
  });

    document.getElementById('notifDismissAllBtn')?.addEventListener('click', () => {
      notifFlyout.classList.add('hidden');
    });
  }

  // Quick Audit & Refresh
  document.getElementById('dashboardScanBtn')?.addEventListener('click', () => triggerScan({ offerElevation: true }));
  document.getElementById('rescanPackagesBtn')?.addEventListener('click', () => triggerScan({ offerElevation: true }));
  document.getElementById('notifDismissAllBtn')?.addEventListener('click', (e) => {
    e.stopPropagation();
    const notifList = document.getElementById('notifFlyoutList');
    const badgeDot = document.getElementById('notifBadgeDot');
    const countBadge = document.getElementById('notifFlyoutBadge');
    if (countBadge) countBadge.textContent = '0';
    if (badgeDot) badgeDot.classList.add('hidden');
    if (notifList) {
      notifList.innerHTML = `
        <div class="notif-empty" id="notifEmptyState">
          <svg class="fluent-icon notif-empty-icon" viewBox="0 0 20 20"><path d="M10 2a8 8 0 1 0 8 8 8.01 8.01 0 0 0-8-8Zm3.7 6.3-4.5 4.5a1 1 0 0 1-1.4 0l-2-2a1 1 0 0 1 1.4-1.4l1.3 1.3 3.8-3.8a1 1 0 1 1 1.4 1.4Z"/></svg>
          <span>All notifications cleared.</span>
        </div>
      `;
    }
  });

  // Watchdog Actions
  document.getElementById('auditWatchdogBtn')?.addEventListener('click', runWatchdogAudit);
  document.getElementById('enforceWatchdogBtn')?.addEventListener('click', () => enforceWatchdog(false));

  // Rollback Actions
  document.getElementById('rollbackLatestBtn')?.addEventListener('click', () => rollbackState('latest', false));
  document.getElementById('whatifRollbackBtn')?.addEventListener('click', () => rollbackState('latest', true));

  // Scheduler Actions
  document.getElementById('saveSchedulerBtn')?.addEventListener('click', saveSchedulerSettings);

  // Preferences Actions
  document.getElementById('savePreferencesBtn')?.addEventListener('click', async () => {
    const theme = document.getElementById('themeSelect')?.value || 'Dark';
    const exclusions = (document.getElementById('exclusionsInput')?.value || '')
      .split(',').map(s => s.trim()).filter(Boolean);

    setDockProgress("Saving", "Updating preferences...", 50, true);
    try {
      await fetch(`${API_BASE}/api/config`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        // The keys the engine reads. These were posted as general.theme and
        // winget.excluded_packages, which nothing on the other side looked at,
        // so an exclusion set here was read back by this page and ignored by
        // the upgrade that was meant to honour it.
        body: JSON.stringify({
          ui: { theme },
          exclusions: { wingetPackageIds: exclusions }
        })
      });
      setDockProgress("Saved", "Application preferences saved successfully.", 100, false);
    } catch (err) {
      setDockProgress("Error", `Failed to save preferences: ${err.message}`, 0, false);
    }
  });

  document.getElementById('resetDefaultsBtn')?.addEventListener('click', () => {
    const themeSel = document.getElementById('themeSelect');
    const exclInp = document.getElementById('exclusionsInput');
    if (themeSel) themeSel.value = 'Dark';
    if (exclInp) exclInp.value = 'Microsoft.Edge, Microsoft.OneDrive';
    window.applyTheme?.('dark');
  });

  // Logs Toolbar
  document.getElementById('logFilterSelect')?.addEventListener('change', () => {
    state.lastLogSig = '';
    renderLogs(true);
  });
  document.getElementById('clearLogsBtn')?.addEventListener('click', () => {
    const filter = document.getElementById('logFilterSelect')?.value || 'ALL';
    const now = Date.now();
    if (filter === 'ALL') {
      state.clearedLevels = { 'ALL': now };
    } else {
      state.clearedLevels[filter] = now;
    }
    state.lastLogSig = '';
    renderLogs(true);
  });
  document.getElementById('exportLogsBtn')?.addEventListener('click', exportLogs);

  // Package Search & Selection
  document.getElementById('packageSearchInput')?.addEventListener('input', renderPackagesTable);
  document.getElementById('masterPackageCheck')?.addEventListener('change', (e) => {
    const checks = document.querySelectorAll('.pkg-checkbox');
    checks.forEach(c => c.checked = e.target.checked);
  });
  document.getElementById('selectAllPackagesBtn')?.addEventListener('click', () => {
    const checks = document.querySelectorAll('.pkg-checkbox');
    checks.forEach(c => c.checked = true);
    const master = document.getElementById('masterPackageCheck');
    if (master) master.checked = true;
  });
  document.getElementById('updateSelectedPackagesBtn')?.addEventListener('click', updateSelectedPackages);

  // Window Titlebar Controls & Auto-Shutdown
  document.querySelector('.win-close')?.addEventListener('click', async () => {
    try { await fetch(`${API_BASE}/api/shutdown`, { method: 'POST' }); } catch {}
    window.close();
  });

  window.addEventListener('beforeunload', () => {
    try { navigator.sendBeacon(`${API_BASE}/api/shutdown`); } catch {}
  });


  // Uninstaller Modal Handlers
  const uninstModal = document.getElementById('uninstallModal');
  document.getElementById('uninstallModalOpenBtn')?.addEventListener('click', () => {
    uninstModal?.classList.remove('hidden');
  });
  document.getElementById('uninstCancelBtn')?.addEventListener('click', () => {
    uninstModal?.classList.add('hidden');
  });
  document.getElementById('uninstConfirmBtn')?.addEventListener('click', async () => {
    const mode = document.querySelector('input[name="uninstMode"]:checked')?.value || 'RestoreDefaults';

    setDockProgress("Uninstalling", "Restoring system defaults and cleaning up...", 50, true);
    uninstModal?.classList.add('hidden');

    try {
      await fetch(`${API_BASE}/api/uninstall`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ mode })
      });
      await fedNotify("FedUpDate has been removed. The application will now close.", { title: "Uninstalled", confirmText: "Close" });
      window.close();
    } catch {
      window.close();
    }
  });
}

// Load Initial Data
async function loadInitialData() {
  try {
    const cfgRes = await fetch(`${API_BASE}/api/config`);
    state.config = await cfgRes.json();
    populateConfigUI();
  } catch (err) {
    console.warn("Config fetch error:", err);
  }

  // Fetch immediate cached scan data for 0ms startup hydration
  try {
    const scanRes = await fetch(`${API_BASE}/api/scan`);
    const initialScan = await scanRes.json();
    if (initialScan.scanData) {
      state.scanData = initialScan.scanData;
      if (Array.isArray(initialScan.scanData.WingetUpdates)) {
        state.packages = initialScan.scanData.WingetUpdates;
      } else if (initialScan.scanData.WingetUpdates) {
        state.packages = [initialScan.scanData.WingetUpdates];
      }
      updateDashboardUI();
      renderPackagesTable();
    }
  } catch (err) {}

  // Awaited so the caller knows when the first audit is genuinely done. The
  // ledger is not part of that and loads alongside.
  loadLedger();
  await triggerScan();
}

// Trigger Deep System Scan
// Resolves when the audit has actually finished rather than when the request to
// start it returns, so a caller can wait for the result. The startup sequence
// waits on this to keep the branding splash up for as long as the first audit
// runs; the button does not care either way.
// A scan that the shield refuses produces no answer about Windows updates, and
// no amount of scanning from this window ever will. Whichever button was pressed,
// the one thing that can answer is offered from here, so no entry point is a dead
// end and none of them has to know anything about how the refusal came about.
async function offerElevatedOSScan() {
  const ok = await fedConfirm(
    'Windows updates could not be checked. The shield keeps the update service disabled, and this window does not run elevated. Checking needs elevation once, and the shield is restored straight afterwards.',
    { title: 'Check Windows updates?', confirmText: 'Check now' }
  );
  if (ok) { await runElevatedOSScan(); }
}

function triggerScan({ offerElevation = false } = {}) {
  setDockProgress("Scanning", "Auditing OS updates, WinGet packages, Store sync, and reboot state...", 25, true);

  return new Promise(async (resolve) => {
    try {
      await fetch(`${API_BASE}/api/scan`, { method: 'POST' });

      let pollCount = 0;
      const scanTimer = setInterval(async () => {
        pollCount++;
        try {
          const res = await fetch(`${API_BASE}/api/scan`);
          const result = await res.json();

          if (result.scanData) {
            state.scanData = result.scanData;
            if (Array.isArray(result.scanData.WingetUpdates)) {
              state.packages = result.scanData.WingetUpdates;
            } else if (result.scanData.WingetUpdates) {
              state.packages = [result.scanData.WingetUpdates];
            } else {
              state.packages = [];
            }
            updateDashboardUI();
            renderPackagesTable();
          }

          if (!result.isScanning || pollCount > 60) {
            clearInterval(scanTimer);
            setDockProgress("Ready", "System scan complete.", 100, false);
            document.getElementById('taskProgressDock')?.classList.add('dock-idle');
            // Asked for by a person, and it could not answer half the question.
            // Saying so and offering the way through belongs here, once, rather
            // than in each button that happens to start a scan.
            if (offerElevation && state.scanData
                && state.scanData.OSScanBlocked && !state.scanData.OSScanCached) {
              await offerElevatedOSScan();
            }
            resolve();
          }
        } catch (err) {
          if (pollCount > 60) {
            clearInterval(scanTimer);
            resolve();
          }
        }
      }, 1200);
    } catch (err) {
      console.error("Scan error:", err);
      setDockProgress("Error", `Scan failed: ${err.message}`, 0, false);
      resolve();
    }
  });
}

// Update Dashboard View Elements
function updateDashboardUI() {
  if (!state.scanData) return;

  const { OSUpdateCount, WingetUpdateCount, StoreUpdateCount, StoreInstalled, WatchdogDrifted,
          OSScanBlocked, OSScanReason, OSScanCached, OSScanCheckedAt } = state.scanData;

  // The badges carry state, not identity: green when there is nothing to do,
  // and one shared colour when there is. Three different colours were used to
  // say the same thing, which read as three unrelated conditions rather than
  // one. Which engine a card belongs to is said by its glyph instead.
  const pending = 'badge-info';

  const osEl = document.getElementById('osBadge');
  if (osEl) {
    // A refused scan has no count. Showing 0 would state a measurement that was
    // never taken, so it says what happened and offers the way to get one.
    if (OSScanBlocked && OSScanCached) {
      // This session could not check, but an elevated one already did, and its
      // answer outlived the process that produced it. Reporting that answer with
      // its age beats reporting nothing on a question already answered.
      osEl.textContent = fedUpdateCountLabel(OSUpdateCount);
      osEl.className = `badge-pill ${(OSUpdateCount || 0) > 0 ? pending : 'badge-green'}`;
      osEl.title = `Checked ${fedRelativeTime(OSScanCheckedAt)}. This window cannot check on its own while the shield is on.`;
    } else if (OSScanBlocked) {
      osEl.textContent = 'Not checked';
      osEl.className = 'badge-pill badge-recommended';
      osEl.title = OSScanReason || 'The Windows Update service is disabled by the shield.';
    } else {
      osEl.textContent = fedUpdateCountLabel(OSUpdateCount);
      osEl.className = `badge-pill ${(OSUpdateCount || 0) > 0 ? pending : 'badge-green'}`;
      osEl.title = '';
    }
  }

  // WinGet Card
  const wingetEl = document.getElementById('wingetBadge');
  if (wingetEl) {
    wingetEl.textContent = `${WingetUpdateCount || 0} Apps Outdated`;
    wingetEl.className = `badge-pill ${(WingetUpdateCount || 0) > 0 ? pending : 'badge-green'}`;
  }

  // Store Card
  const storeEl = document.getElementById('storeBadge');
  if (storeEl) {
    if (StoreUpdateCount !== undefined && StoreUpdateCount !== null) {
      storeEl.textContent = `${StoreUpdateCount} Apps Outdated`;
      storeEl.className = `badge-pill ${StoreUpdateCount > 0 ? pending : 'badge-green'}`;
    } else {
      storeEl.textContent = StoreInstalled ? 'Sync Ready' : 'Not Found';
    }
  }

  // Render OS Updates Table
  renderOSUpdatesTable();

  // Update Notification Center Flyout & Badge
  updateNotificationsUI();
}

// Notification Center Controller
function updateNotificationsUI() {
  const notifList = document.getElementById('notifFlyoutList');
  const badgeDot = document.getElementById('notifBadgeDot');
  const countBadge = document.getElementById('notifFlyoutBadge');
  if (!notifList || !state.scanData) return;

  const items = [];
  const { OSUpdateCount, WingetUpdateCount, StoreUpdateCount, RebootSeverity, RebootReasons, RebootPendingFiles, RebootSurvivedBoot, WatchdogDrifted,
          OSScanBlocked, OSScanReason, OSScanCached, OSScanCheckedAt } = state.scanData;

  if (WatchdogDrifted) {
    items.push({
      id: 'watchdog-drift',
      type: 'urgent',
      icon: '🛡️',
      title: 'Anti-Tamper Drift Alert',
      desc: 'Windows has silently modified update policies. System background sync has drifted.',
      actionText: 'Enforce Guard',
      actionHandler: 'enforceWatchdog(false)'
    });
  }

  // A restart the system is genuinely waiting on, and routine installer cleanup
  // queued for the next restart, are different things and are shown differently.
  // Presenting cleanup as an urgent alert is what trained people to ignore this
  // list, because the alert never cleared.
  if (RebootSeverity === 'Required') {
    const staleNote = RebootSurvivedBoot
      ? ' Some of this predates your last restart, so restarting again will not clear it.'
      : '';
    items.push({
      id: 'reboot-pending',
      type: 'urgent',
      icon: '⚠️',
      title: 'System Reboot Required',
      desc: ((RebootReasons && RebootReasons.length > 0)
        ? RebootReasons.join(' ')
        : 'A restart is needed to finish installing updates.') + staleNote,
      actions: [
        { text: 'Restart Now', handler: 'forceRestart()', class: 'btn-primary' },
        { text: 'Shut Down', handler: 'forceShutdown()', class: 'btn-secondary' }
      ]
    });
  } else if (RebootSeverity === 'Advisory') {
    const files = (RebootPendingFiles || []).slice(0, 3);
    const extra = (RebootPendingFiles || []).length - files.length;
    const detail = files.length
      ? ` Queued: ${files.join(', ')}${extra > 0 ? ` and ${extra} more` : ''}.`
      : '';
    items.push({
      id: 'reboot-advisory',
      type: 'info',
      // Depicts the subject, housekeeping, rather than the severity. Every other
      // card's glyph says what it is about; the type says how much it matters.
      icon: '🧹',
      title: 'Cleanup Queued For Next Restart',
      desc: ((RebootReasons && RebootReasons.length > 0)
        ? RebootReasons.join(' ')
        : 'An installer has queued files for removal at the next restart.')
        + detail
        + ' No action is needed.'
    });
  }

  if (OSScanBlocked && !OSScanCached) {
    items.push({
      id: 'os-scan-blocked',
      type: 'warn',
      icon: '🛡️',
      title: 'Windows Updates Not Checked',
      desc: (OSScanReason || 'The Windows Update service is disabled by the anti-tamper shield.')
        + ' Checking needs elevation once. The shield is restored straight afterwards.',
      actionText: 'Check now',
      actionHandler: 'runElevatedOSScan()'
    });
  }

  if ((!OSScanBlocked || OSScanCached) && (OSUpdateCount || 0) > 0) {
    items.push({
      id: 'os-updates',
      type: 'warn',
      icon: '📦',
      title: `${OSUpdateCount} OS Update(s) Pending`,
      desc: 'Windows quality / security updates ready.',
      actionText: 'Go to OS Updates',
      actionHandler: "window.navigateTo('osupdates')"
    });
  }

  if ((WingetUpdateCount || 0) > 0) {
    items.push({
      id: 'winget-updates',
      type: 'warn',
      icon: '⚡',
      title: `${WingetUpdateCount} App Update(s) Available`,
      desc: 'New releases available for installed packages.',
      actionText: 'View Packages',
      actionHandler: "window.navigateTo('packages')"
    });
  }

  // Update Bell Badge
  if (countBadge) countBadge.textContent = items.length;
  if (badgeDot) {
    badgeDot.classList.toggle('hidden', items.length === 0);
  }

  // Render Flyout Items
  if (items.length === 0) {
    notifList.innerHTML = `
      <div class="notif-empty" id="notifEmptyState">
        <svg class="fluent-icon notif-empty-icon" viewBox="0 0 20 20"><path d="M10 2a8 8 0 1 0 8 8 8.01 8.01 0 0 0-8-8Zm3.7 6.3-4.5 4.5a1 1 0 0 1-1.4 0l-2-2a1 1 0 0 1 1.4-1.4l1.3 1.3 3.8-3.8a1 1 0 1 1 1.4 1.4Z"/></svg>
        <span>All systems optimal. No pending alerts.</span>
      </div>
    `;
    return;
  }

  notifList.innerHTML = items.map(item => `
    <div class="notif-item notif-${item.type}">
      <div class="notif-item-header">
        <span class="notif-item-title">${item.icon} ${escapeHtml(item.title)}</span>
      </div>
      <span class="notif-item-desc">${escapeHtml(item.desc)}</span>
      ${(item.actions || item.actionHandler) ? `
      <div class="notif-item-actions">
        ${item.actions ? item.actions.map(act => `<button class="btn ${act.class || 'btn-secondary'} btn-sm" onclick="${act.handler}">${act.text}</button>`).join(' ') : `<button class="btn btn-secondary btn-sm" onclick="${item.actionHandler}">${item.actionText}</button>`}
      </div>` : ''}
    </div>
  `).join('');
}

async function runElevatedOSScan() {
  setDockProgress("Checking", "Asking for elevation to check Windows updates...", 30, true);
  try {
    const res = await fetch(`${API_BASE}/api/scan/elevated`, { method: 'POST' });
    const out = await res.json();
    if (out && out.success) {
      await triggerScan();
    } else {
      setDockProgress("Not checked", "Elevation was declined. The shield is untouched.", 0, false);
      await fedNotify("Windows updates were not checked because elevation was declined. Nothing was changed.", { title: "Not checked" });
    }
  } catch (err) {
    setDockProgress("Error", `Could not check: ${err.message}`, 0, false);
  }
}

async function forceRestart() {
  if (await fedConfirm("This restarts the computer now. Anything unsaved in other applications will be lost.", { title: "Restart now?", confirmText: "Restart now", danger: true })) {
    setDockProgress("Rebooting", "Issuing system restart...", 90, true);
    try {
      await fetch(`${API_BASE}/api/reboot/force`, { method: 'POST' });
    } catch {}
  }
}

async function forceShutdown() {
  if (await fedConfirm("This finishes the pending work and powers the computer off. Anything unsaved in other applications will be lost.", { title: "Shut down now?", confirmText: "Shut down", danger: true })) {
    setDockProgress("Shutting Down", "Finalizing updates and powering off system...", 95, true);
    try {
      await fetch(`${API_BASE}/api/reboot/shutdown`, { method: 'POST' });
    } catch {}
  }
}

// Render WinGet Packages Table
function renderPackagesTable() {
  const tbody = document.getElementById('packagesTableBody');
  const query = (document.getElementById('packageSearchInput').value || '').toLowerCase();

  const filtered = state.packages.filter(pkg => 
    (pkg.Name && pkg.Name.toLowerCase().includes(query)) ||
    (pkg.Id && pkg.Id.toLowerCase().includes(query)) ||
    (pkg.Source && pkg.Source.toLowerCase().includes(query))
  );

  if (filtered.length === 0) {
    tbody.innerHTML = `
      <tr class="placeholder-row">
        <td colspan="7">${state.packages.length === 0 ? 'All packages are up-to-date!' : 'No matching packages found.'}</td>
      </tr>
    `;
    return;
  }

  tbody.innerHTML = filtered.map(pkg => `
    <tr>
      <td><input type="checkbox" class="pkg-checkbox" data-id="${pkg.Id}" checked></td>
      <td style="font-weight: 600;">${escapeHtml(pkg.Name)}</td>
      <td style="font-family: 'JetBrains Mono', monospace; font-size: 11.5px; color: var(--text-secondary);">${escapeHtml(pkg.Id)}</td>
      <td><span class="badge-pill badge-info">${escapeHtml(pkg.CurrentVersion)}</span></td>
      <td><span class="badge-pill badge-recommended">${escapeHtml(pkg.AvailableVersion)}</span></td>
      <td><span class="badge-pill badge-purple">${escapeHtml(pkg.Source || 'winget')}</span></td>
      <td>
        <button class="btn btn-secondary btn-sm" onclick="updateSinglePackage('${escapeHtml(pkg.Id)}')">Upgrade</button>
      </td>
    </tr>
  `).join('');
}

// Render Windows OS & Defender Updates Table
function renderOSUpdatesTable() {
  const tbody = document.getElementById('osUpdatesTableBody');
  if (!tbody) return;

  // A refused scan yields no rows, which looks exactly like a scan that ran and
  // found nothing. Declaring the system up to date on the strength of a check
  // that never happened is the one thing this table must never do, so the
  // refusal is reported as itself, with the way to resolve it.
  if (state.scanData && state.scanData.OSScanBlocked && !state.scanData.OSScanCached) {
    const reason = state.scanData.OSScanReason
      || 'The Windows Update service is disabled by the anti-tamper shield.';
    tbody.innerHTML = `
      <tr class="placeholder-row">
        <td colspan="6">
          Windows updates were not checked. ${escapeHtml(reason)}
          Checking needs elevation once, and the shield is restored straight afterwards.
          <button class="btn btn-secondary btn-sm" onclick="runElevatedOSScan()">Check now</button>
        </td>
      </tr>
    `;
    return;
  }

  const osUpdates = (state.scanData && Array.isArray(state.scanData.OSUpdates)) ? state.scanData.OSUpdates : [];
  const cachedNote = (state.scanData && state.scanData.OSScanBlocked && state.scanData.OSScanCached)
    ? `<tr class="placeholder-row"><td colspan="6">Checked ${escapeHtml(fedRelativeTime(state.scanData.OSScanCheckedAt))}, with elevation. This window cannot check on its own while the shield is on. <button class="btn btn-secondary btn-sm" onclick="runElevatedOSScan()">Check again</button></td></tr>`
    : '';

  if (osUpdates.length === 0) {
    tbody.innerHTML = cachedNote + `
      <tr class="placeholder-row">
        <td colspan="6">Windows is fully up-to-date! No pending OS or Defender updates.</td>
      </tr>
    `;
    return;
  }

  tbody.innerHTML = cachedNote + osUpdates.map(u => `
    <tr>
      <td style="font-weight: 600;">${escapeHtml(u.Title || 'Windows Update')}</td>
      <td><span class="badge-pill badge-info">${escapeHtml((u.KB && u.KB !== 'N/A') ? u.KB : 'No KB')}</span></td>
      <td><span class="badge-pill ${u.IsSecurity ? 'badge-danger' : (u.IsDefender ? 'badge-purple' : 'badge-green')}">${u.IsDefender ? 'Defender Intelligence' : (u.IsSecurity ? 'Security Update' : 'Quality Update')}</span></td>
      <td>${u.SizeMB ? u.SizeMB + ' MB' : 'Dynamic CDN'}</td>
      <td><span class="badge-pill ${u.RebootRequired ? 'badge-amber' : 'badge-green'}">${u.RebootRequired ? 'Reboot Required' : 'Zero Reboot'}</span></td>
      <td>
        <button class="btn btn-secondary btn-sm" onclick="executeTargetUpdate({ os: true })">Install</button>
      </td>
    </tr>
  `).join('');
}

// Execute Targeted or Unified Updates (OS, WinGet, Store, or All)
async function executeTargetUpdate({ os = false, winget = false, store = false, all = false, isWhatIf = false } = {}) {
  if (state.isExecuting) return;
  state.isExecuting = true;

  let includeOS = os;
  let includeWinget = winget;
  let includeStore = store;

  if (all || (!os && !winget && !store)) {
    includeOS = document.getElementById('checkIncludeOS')?.checked ?? true;
    includeWinget = document.getElementById('checkIncludeWinget')?.checked ?? true;
    includeStore = document.getElementById('checkIncludeStore')?.checked ?? true;
  }

  const targets = [];
  if (includeOS) targets.push("Windows OS");
  if (includeWinget) targets.push("WinGet");
  if (includeStore) targets.push("Microsoft Store");
  const targetLabel = targets.join(' + ') || "Selected Engines";

  const taskTitle = isWhatIf ? `Simulating ${targetLabel} (WhatIf)` : `Updating ${targetLabel}`;
  setDockProgress(taskTitle, `Executing update workflow for ${targetLabel}...`, 20, true);

  try {
    const res = await fetch(`${API_BASE}/api/update`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        os: includeOS,
        winget: includeWinget,
        store: includeStore,
        whatif: isWhatIf,
        rebootPolicy: document.getElementById('rebootPolicySelect')?.value || 'Smart'
      })
    });

    await res.json();

    // The POST only starts the run: the server executes it in a background
    // runspace and answers immediately. Treating that answer as completion
    // reported success while the work was still going and refreshed the
    // dashboard from pre-update state, so the counts never moved.
    setDockProgress(taskTitle, `Working through ${targetLabel}...`, 45, true);
    const finished = await waitForUpdateCompletion();

    if (finished) {
      setDockProgress("Complete", isWhatIf ? "Simulation completed successfully." : `Finished updating ${targetLabel}.`, 100, false);
    } else {
      setDockProgress("Still running", "The update is taking longer than expected. See the logs for progress.", 100, false);
    }

    await triggerScan();
    await loadLedger();
  } catch (err) {
    setDockProgress("Error", `Update failed: ${err.message}`, 0, false);
  } finally {
    state.isExecuting = false;
  }
}

// Polls until the background update reports it has finished. A GET also causes
// the server to harvest the completed run, so polling is what makes its results
// available. The ceiling matches the engine's own thirty minute limit.
async function waitForUpdateCompletion({ intervalMs = 2000, timeoutMs = 1800000 } = {}) {
  const startedAt = Date.now();

  while (Date.now() - startedAt < timeoutMs) {
    await new Promise(resolve => setTimeout(resolve, intervalMs));
    try {
      const res = await fetch(`${API_BASE}/api/update`);
      const data = await res.json();
      if (data.isRunning === false) return true;
    } catch (err) {
      // A refused poll is not fatal: the run continues and the next poll retries.
      console.warn("Update poll failed:", err);
    }
  }
  return false;
}

// Update Single / Selected WinGet Packages
async function updateSinglePackage(packageId) {
  setDockProgress("Upgrading", `Downloading & upgrading ${packageId}...`, 30, true);
  try {
    await fetch(`${API_BASE}/api/update/winget`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ packages: [packageId] })
    });
    
    let pollCount = 0;
    const pollTimer = setInterval(async () => {
      pollCount++;
      try {
        const res = await fetch(`${API_BASE}/api/update`);
        const status = await res.json();
        if (!status.isRunning || pollCount > 90) {
          clearInterval(pollTimer);
          setDockProgress("Complete", `Finished upgrading ${packageId}`, 100, false);
          state.packages = state.packages.filter(p => p.Id !== packageId);
          if (state.scanData) {
            state.scanData.WingetUpdateCount = state.packages.length;
            if (Array.isArray(state.scanData.WingetUpdates)) {
              state.scanData.WingetUpdates = state.packages;
            }
          }
          renderPackagesTable();
          updateDashboardUI();
          await triggerScan();
        }
      } catch (e) {
        if (pollCount > 90) clearInterval(pollTimer);
      }
    }, 1000);
  } catch (err) {
    setDockProgress("Error", `Failed to upgrade ${packageId}`, 0, false);
  }
}

async function updateSelectedPackages() {
  const selectedIds = Array.from(document.querySelectorAll('.pkg-checkbox:checked')).map(cb => cb.dataset.id);
  if (selectedIds.length === 0) {
    await fedNotify("Select at least one package before upgrading.", { title: "Nothing selected" });
    return;
  }

  setDockProgress("Upgrading", `Downloading & upgrading ${selectedIds.length} package(s)...`, 25, true);
  try {
    await fetch(`${API_BASE}/api/update/winget`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ packages: selectedIds })
    });
    
    let pollCount = 0;
    const pollTimer = setInterval(async () => {
      pollCount++;
      try {
        const res = await fetch(`${API_BASE}/api/update`);
        const status = await res.json();
        if (!status.isRunning || pollCount > 90) {
          clearInterval(pollTimer);
          setDockProgress("Complete", `Upgraded ${selectedIds.length} package(s).`, 100, false);
          state.packages = state.packages.filter(p => !selectedIds.includes(p.Id));
          if (state.scanData) {
            state.scanData.WingetUpdateCount = state.packages.length;
            if (Array.isArray(state.scanData.WingetUpdates)) {
              state.scanData.WingetUpdates = state.packages;
            }
          }
          renderPackagesTable();
          updateDashboardUI();
          await triggerScan();
        }
      } catch (e) {
        if (pollCount > 90) clearInterval(pollTimer);
      }
    }, 1000);
  } catch (err) {
    setDockProgress("Error", `Failed to upgrade selected packages: ${err.message}`, 0, false);
  }
}

// Watchdog Functions
async function runWatchdogAudit() {
  setDockProgress("Auditing", "Auditing Windows update service states and policies...", 40, true);
  try {
    const res = await fetch(`${API_BASE}/api/watchdog/audit`);
    const audit = await res.json();
    if (!state.scanData) state.scanData = {};
    state.scanData.WatchdogDrifted = audit.HasDrifted;
    updateDashboardUI();
    setDockProgress("Audit Complete", audit.HasDrifted ? "Drift detected in Windows services." : "All policies in desired state.", 100, false);
    setTimeout(() => {
      document.getElementById('taskProgressDock')?.classList.add('dock-idle');
    }, 2500);
  } catch (err) {
    setDockProgress("Error", `Watchdog audit failed: ${err.message}`, 0, false);
  }
}

async function enforceWatchdog(isWhatIf = false) {
  setDockProgress(isWhatIf ? "Simulating Guard" : "Enforcing Guard", "Locking down Windows update hijackers...", 50, true);
  if (!isWhatIf && state.scanData) {
    state.scanData.WatchdogDrifted = false;
    updateNotificationsUI();
  }
  document.getElementById('notifFlyout')?.classList.add('hidden');
  try {
    await fetch(`${API_BASE}/api/watchdog/enforce`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ whatif: isWhatIf })
    });
    setDockProgress("Complete", "Anti-tamper policies enforced.", 100, false);
    await triggerScan();
    await loadLedger();
  } catch (err) {
    setDockProgress("Error", `Enforce failed: ${err.message}`, 0, false);
  }
}

// Rollback & Ledger Functions
async function loadLedger() {
  try {
    const res = await fetch(`${API_BASE}/api/rollback/ledger`);
    const ledger = await res.json();
    state.ledger = Array.isArray(ledger) ? ledger : [];
    renderLedgerTimeline();
  } catch (err) {
    console.warn("Failed to load ledger:", err);
  }
}

function renderLedgerTimeline() {
  const container = document.getElementById('ledgerTimeline');
  if (state.ledger.length === 0) {
    container.innerHTML = `<div class="timeline-card"><div class="timeline-info"><div class="timeline-desc">No state transactions recorded yet.</div></div></div>`;
    return;
  }

  const sorted = [...state.ledger].reverse();
  container.innerHTML = sorted.map(tx => `
    <div class="timeline-card">
      <div class="timeline-info">
        <span class="timeline-tx-id">${escapeHtml(tx.Id)}</span>
        <div class="timeline-desc">${escapeHtml(tx.Description)}</div>
        <div class="timeline-time">${escapeHtml(tx.Timestamp)} &bull; ${tx.Changes ? tx.Changes.length : 0} operations recorded</div>
      </div>
      <div class="header-actions">
        <button class="btn btn-secondary btn-sm" onclick="rollbackState('${escapeHtml(tx.Id)}', true)">WhatIf</button>
        <button class="btn btn-danger btn-sm" onclick="rollbackState('${escapeHtml(tx.Id)}', false)">Revert Snapshot</button>
      </div>
    </div>
  `).join('');
}

async function rollbackState(txId, isWhatIf = false) {
  const promptText = isWhatIf 
    ? `Simulate rollback for transaction '${txId}'?` 
    : `Are you sure you want to revert transaction '${txId}' and restore original settings?`;

  if (!(await fedConfirm(promptText, { title: isWhatIf ? "Simulate rollback" : "Revert this change?", confirmText: isWhatIf ? "Simulate" : "Revert", danger: !isWhatIf }))) return;

  setDockProgress("Rolling back", `Restoring snapshot ${txId}...`, 40, true);
  try {
    await fetch(`${API_BASE}/api/rollback/restore`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ transactionId: txId === 'latest' ? null : txId, latest: txId === 'latest', whatif: isWhatIf })
    });
    setDockProgress("Complete", isWhatIf ? "Rollback simulation complete." : "State restored successfully.", 100, false);
    await triggerScan();
    await loadLedger();
  } catch (err) {
    setDockProgress("Error", `Rollback failed: ${err.message}`, 0, false);
  }
}

// Scheduler Settings
async function saveSchedulerSettings() {
  const enabled = document.getElementById('schedulerEnabledToggle').checked;
  const frequency = document.getElementById('schedFrequencySelect').value;
  const time = document.getElementById('schedTimeInput').value;

  setDockProgress("Saving", "Configuring Windows Task Scheduler...", 50, true);
  try {
    await fetch(`${API_BASE}/api/schedule/set`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled, frequency, time })
    });
    setDockProgress("Saved", "Schedule updated.", 100, false);
  } catch (err) {
    setDockProgress("Error", `Failed to save schedule: ${err.message}`, 0, false);
  }
}

// Populate Config UI
function populateConfigUI() {
  if (!state.config) return;
  const cfg = state.config;

  if (cfg.ui && cfg.ui.theme) {
    const t = cfg.ui.theme;
    if (t === 'System') {
      const sysLight = window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches;
      window.applyTheme(sysLight ? 'light' : 'dark');
    } else {
      window.applyTheme(t.toLowerCase() === 'light' ? 'light' : 'dark');
    }
  }

  if (cfg.rebootPolicy) {
    const rbSelect = document.getElementById('rebootPolicySelect');
    if (rbSelect) rbSelect.value = cfg.rebootPolicy;
  }

  // Anything unrecognised reads as stable, matching what the engine decides,
  // so the control never claims a channel the engine is not following.
  const channel = String(cfg.updateChannel || '').toLowerCase() === 'beta' ? 'beta' : 'stable';
  const chSelect = document.getElementById('updateChannelSelect');
  if (chSelect) chSelect.value = channel;
  const chBadge = document.getElementById('updateChannelBadge');
  if (chBadge) chBadge.textContent = channel === 'beta' ? 'Beta' : 'Stable';

  if (cfg.exclusions && cfg.exclusions.wingetPackageIds) {
    const exInput = document.getElementById('exclusionsInput');
    if (exInput) exInput.value = cfg.exclusions.wingetPackageIds.join(', ');
  }

  if (cfg.scheduler) {
    const sEnabled = document.getElementById('schedulerEnabledToggle');
    const sFreq = document.getElementById('schedFrequencySelect');
    const sTime = document.getElementById('schedTimeInput');
    if (sEnabled && cfg.scheduler.enabled !== undefined) sEnabled.checked = cfg.scheduler.enabled;
    if (sFreq && cfg.scheduler.frequency) sFreq.value = cfg.scheduler.frequency;
    if (sTime && cfg.scheduler.time) sTime.value = cfg.scheduler.time;
  }
}

// Logs Polling & Rendering
function startLogPolling() {
  setInterval(async () => {
    try {
      const res = await fetch(`${API_BASE}/api/logs`);
      const newLogs = await res.json();
      if (Array.isArray(newLogs) && newLogs.length > 0) {
        state.logs = newLogs;
        renderLogs(false);

        // Update latest line in bottom dock
        const lastLog = newLogs[newLogs.length - 1];
        if (lastLog) {
          const dockLine = document.getElementById('dockTerminalLine');
          if (dockLine) dockLine.textContent = `[${lastLog.Component}] ${lastLog.Message}`;
        }
      }
    } catch { }
  }, 1000);
}

function renderLogs(forceScroll = false) {
  const body = document.getElementById('terminalLogsBody');
  const filter = document.getElementById('logFilterSelect')?.value || 'ALL';
  if (!body) return;

  // Filter logs by cleared timestamp of the active level and selected severity
  const filtered = state.logs.filter(l => {
    const levelClearedAt = state.clearedLevels[l.Level] || state.clearedLevels['ALL'] || 0;
    if (levelClearedAt && l.Timestamp) {
      const logTime = new Date(l.Timestamp).getTime();
      if (!isNaN(logTime) && logTime <= levelClearedAt) return false;
    }
    return filter === 'ALL' || l.Level === filter;
  });

  // If logs haven't changed and filter hasn't changed, do not disturb DOM or scroll position
  const currentSig = `${filter}-${filtered.length}-${filtered[filtered.length - 1]?.Timestamp || ''}-${JSON.stringify(state.clearedLevels)}`;
  if (!forceScroll && state.lastLogSig === currentSig) {
    return;
  }
  state.lastLogSig = currentSig;

  // Detect if user is currently scrolled near the bottom (within 40px)
  const isAtBottom = (body.scrollHeight - body.scrollTop - body.clientHeight) < 40;

  if (filtered.length === 0) {
    body.innerHTML = '<div class="log-line" style="color: var(--sys-color-text-muted); font-style: italic; padding: 0.5rem;">No log entries to display for current filter.</div>';
    return;
  }

  body.innerHTML = filtered.map(l => {
    const time = (l.Timestamp && l.Timestamp.includes(' ')) ? l.Timestamp.split(' ')[1] : l.Timestamp;
    return `<div class="log-line log-line-${l.Level}">[${escapeHtml(time)}] [${escapeHtml(l.Level.padEnd(5))}] [${escapeHtml(l.Component)}] ${escapeHtml(l.Message)}</div>`;
  }).join('');

  // Auto-scroll to bottom ONLY if the user was already at the bottom or forceScroll is true
  if (isAtBottom || forceScroll) {
    body.scrollTop = body.scrollHeight;
  }
}

async function exportLogs() {
  const filter = document.getElementById('logFilterSelect')?.value || 'ALL';
  const filtered = state.logs.filter(l => {
    const levelClearedAt = state.clearedLevels[l.Level] || state.clearedLevels['ALL'] || 0;
    if (levelClearedAt && l.Timestamp) {
      const logTime = new Date(l.Timestamp).getTime();
      if (!isNaN(logTime) && logTime <= levelClearedAt) return false;
    }
    return filter === 'ALL' || l.Level === filter;
  });

  if (filtered.length === 0) {
    await fedNotify("No log entries match the current filter, so there is nothing to export.", { title: "Nothing to export" });
    return;
  }

  const text = filtered.map(l => `[${l.Timestamp}] [${l.Level.padEnd(5)}] [${l.Component}] ${l.Message}`).join('\r\n');
  const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  
  const filterSlug = filter.toLowerCase();
  const dateStr = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  a.download = `fedupdate-logs-${filterSlug}-${dateStr}.log`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// Bottom Task Progress Dock Helper
function setDockProgress(taskName, terminalLine, percent, isIndeterminate = false) {
  const dock = document.getElementById('taskProgressDock');
  const taskEl = document.getElementById('dockTaskName');
  const termEl = document.getElementById('dockTerminalLine');
  const bar = document.getElementById('dockProgressBar');
  const queueEl = document.getElementById('dockQueueStatus');

  if (taskEl) taskEl.textContent = taskName;
  if (termEl) termEl.textContent = terminalLine;
  if (queueEl) {
    queueEl.textContent = isIndeterminate ? 'Operation in progress...' : (percent === 100 ? 'Engine idle & synchronized' : 'Processing update batch...');
  }

  if (bar) {
    bar.style.width = `${percent}%`;
    bar.classList.toggle('indeterminate', isIndeterminate);
  }

  if (dock) {
    if (taskName === "Ready" && percent === 100 && !isIndeterminate) {
      dock.classList.add('dock-idle');
    } else {
      dock.classList.remove('dock-idle');
    }
  }
}

// Version corner. The installed version comes from the server, which reads it
// from CHANGELOG.md, so the UI cannot show a stale hardcoded string.
let versionState = { current: null, latest: null, updateAvailable: false, releases: null };

async function loadVersionInfo() {
  const badge = document.getElementById('appVersionBadge');
  const glyph = document.getElementById('versionGlyphBtn');
  const dot = document.getElementById('versionGlyphDot');
  const sub = document.getElementById('versionFlyoutSub');
  const updateBtn = document.getElementById('versionUpdateBtn');

  let info = null;
  try {
    const res = await fetch(`${API_BASE}/api/version`);
    info = await res.json();
  } catch (err) {
    console.warn("Version lookup failed:", err);
  }

  if (!info || !info.Current) {
    if (badge) badge.textContent = '';
    if (sub) sub.textContent = 'Version unavailable';
    return;
  }

  versionState.current = info.Current;
  versionState.latest = info.Latest;
  versionState.updateAvailable = info.UpdateAvailable === true;

  if (badge) badge.textContent = `v${info.Current}`;

  // "Up to date" is only true when a release was actually read. An unreachable
  // check, or a channel with nothing published on it yet, is not the same thing
  // as being current and must not be reported as if it were.
  const reachable = info.RemoteReachable === true;
  const channel = info.Channel || 'stable';

  // How far the channel's branch has moved since this version, which a tag on
  // its own cannot say.
  const since = Number.isFinite(info.CommitsSince) ? info.CommitsSince : null;
  const sinceText = (since && since > 0)
    ? `, ${since} commit${since === 1 ? '' : 's'} on ${info.Branch || 'main'} since`
    : '';

  let summary;
  if (versionState.updateAvailable) {
    summary = `v${info.Current} - v${info.Latest} available`;
  } else if (!reachable) {
    summary = `v${info.Current} - no ${channel} release to compare against`;
  } else {
    summary = `v${info.Current} - up to date`;
  }

  // The glyph carries the installed version on hover, so no text is needed
  // beside it in the corner.
  if (glyph) {
    glyph.title = `FedUpDate ${summary}${sinceText} (${channel} channel)`;
    glyph.classList.toggle('has-update', versionState.updateAvailable);
  }
  dot?.classList.toggle('hidden', !versionState.updateAvailable);
  updateBtn?.classList.toggle('hidden', !versionState.updateAvailable);

  if (sub) sub.textContent = `${summary}${sinceText}`;

  if (updateBtn && !updateBtn.dataset.bound) {
    updateBtn.dataset.bound = '1';
    updateBtn.addEventListener('click', runSelfUpdate);
  }
}

// Release notes are fetched once and cached, both here and on the server: the
// unauthenticated GitHub API allows only 60 requests an hour per machine.
async function loadReleaseNotes() {
  if (versionState.releases) return versionState.releases;
  try {
    const res = await fetch(`${API_BASE}/api/changelog`);
    const data = await res.json();
    versionState.releases = Array.isArray(data.releases) ? data.releases : [];
  } catch (err) {
    console.warn("Release notes lookup failed:", err);
    versionState.releases = [];
  }
  return versionState.releases;
}

function renderReleaseNotes(releases) {
  const body = document.getElementById('versionFlyoutBody');
  if (!body) return;

  if (!releases.length) {
    body.innerHTML = `<div class="version-empty">You are on the latest version.</div>`;
    return;
  }

  // Newest expanded, older ones collapsed to their heading. Keeps the popover a
  // predictable size however many versions behind the user is.
  body.innerHTML = releases.map((r, i) => `
    <div class="release-entry">
      <button class="release-heading${i === 0 ? ' is-open' : ''}" data-release-index="${i}" aria-expanded="${i === 0}">
        <svg class="release-chevron" viewBox="0 0 20 20" aria-hidden="true"><path d="M7.5 5.5a.75.75 0 0 1 1.06 0l4 4a.75.75 0 0 1 0 1.06l-4 4a.75.75 0 0 1-1.06-1.06L10.94 10 7.5 6.56a.75.75 0 0 1 0-1.06Z"/></svg>
        <span class="release-version">${escapeHtml(r.Version)}</span>
        <span class="release-date">${escapeHtml(r.PublishedAt || '')}</span>
      </button>
      <div class="release-body${i === 0 ? '' : ' hidden'}" id="releaseBody-${i}">${escapeHtml(r.Body || '')}</div>
    </div>
  `).join('');

  body.querySelectorAll('.release-heading').forEach(btn => {
    btn.addEventListener('click', () => {
      const target = document.getElementById(`releaseBody-${btn.dataset.releaseIndex}`);
      if (!target) return;
      const nowOpen = target.classList.toggle('hidden') === false;
      btn.classList.toggle('is-open', nowOpen);
      btn.setAttribute('aria-expanded', String(nowOpen));
    });
  });
}

async function toggleVersionFlyout() {
  const flyout = document.getElementById('versionFlyout');
  if (!flyout) return;

  const opening = flyout.classList.contains('hidden');
  flyout.classList.toggle('hidden', !opening);
  if (!opening) return;

  renderReleaseNotes(await loadReleaseNotes());
}

async function runSelfUpdate() {
  const btn = document.getElementById('versionUpdateBtn');
  if (btn) { btn.disabled = true; btn.textContent = 'Updating...'; }
  setDockProgress("Updating FedUpDate", "Downloading and installing the latest release...", 30, true);

  try {
    const res = await fetch(`${API_BASE}/api/self-update`, { method: 'POST' });
    const result = await res.json();
    if (result.success) {
      setDockProgress("Update complete", "Restart FedUpDate to run the new version.", 100, false);
    } else {
      setDockProgress("Update failed", "See the logs for details.", 100, false);
    }
  } catch (err) {
    setDockProgress("Update failed", String(err), 100, false);
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Update now'; }
    versionState.releases = null;
    await loadVersionInfo();
  }
}

// Helper: Escape HTML
// A recovered result is only worth showing if it is dated, because the value of
// "3 pending" depends entirely on whether that was measured a minute or a month
// ago, and this window cannot take a fresh measurement on its own.
// Not every Windows update has a KB article. Driver and optional updates
// generally have none, so counting them as KBs named them after an identifier
// they do not carry and that nothing else on the system would show.
function fedUpdateCountLabel(n) {
  const count = n || 0;
  if (count === 0) return 'No updates pending';
  return count === 1 ? '1 update pending' : `${count} updates pending`;
}

function fedRelativeTime(iso) {
  if (!iso) return 'earlier';
  const then = new Date(iso);
  if (isNaN(then.getTime())) return 'earlier';
  const mins = Math.floor((Date.now() - then.getTime()) / 60000);
  if (mins < 1) return 'just now';
  if (mins === 1) return '1 minute ago';
  if (mins < 60) return `${mins} minutes ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs === 1) return '1 hour ago';
  if (hrs < 24) return `${hrs} hours ago`;
  const days = Math.floor(hrs / 24);
  return days === 1 ? 'yesterday' : `${days} days ago`;
}

function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

