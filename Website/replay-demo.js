const clipLengths = [
  5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60,
  90, 120, 150, 180, 240, 300, 360, 420, 480, 540, 600,
  900, 1200, 1500, 1800, 2100, 2400, 2700, 3000, 3300, 3600
];

function formatClipLength(seconds) {
  const units = [
    [Math.floor(seconds / 3600), 'hour'],
    [Math.floor(seconds % 3600 / 60), 'minute'],
    [seconds % 60, 'second']
  ];
  return units.filter(([value]) => value > 0)
    .map(([value, unit]) => `${value} ${unit}${value === 1 ? '' : 's'}`)
    .join(' ');
}

function initializeReplayDemo(demo) {
  const camera = demo.querySelector('[data-demo-camera]');
  const settings = demo.querySelector('[data-demo-settings]');
  const saved = demo.querySelector('[data-demo-saved]');
  const replay = demo.querySelector('[data-demo-replay]');
  const live = demo.querySelector('[data-demo-live]');
  const trigger = demo.querySelector('[data-demo-trigger]');
  const triggerLabel = demo.querySelector('[data-demo-trigger-label]');
  const zoomButtons = demo.querySelectorAll('[data-demo-zoom]');
  const openSettings = demo.querySelector('[data-demo-open-settings]');
  const done = demo.querySelector('[data-demo-done]');
  const length = demo.querySelector('[data-demo-length]');
  const duration = demo.querySelector('[data-demo-duration]');
  const status = demo.querySelector('[data-demo-status]');
  const savedDuration = demo.querySelector('[data-demo-saved-duration]');
  const thumbnail = demo.querySelector('[data-demo-thumbnail]');
  const play = demo.querySelector('[data-demo-play]');
  const next = demo.querySelector('[data-demo-next]');
  const video = demo.querySelector('[data-demo-video]');
  const again = demo.querySelector('[data-demo-again]');
  const back = demo.querySelector('[data-demo-back]');
  const panels = [camera, settings, saved, replay];

  if ([
    ...panels, live, trigger, openSettings, done, length, duration, status,
    savedDuration, thumbnail, play, next, video, again, back
  ].some((element) => !element)) return;

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const startMessage = 'Tap the camera to start the sample.';
  const minimumClip = 0.75;
  let currentPanel = camera;
  let inView = false;
  let cameraRequested = false;
  let cameraFailed = false;
  let previousLength = length.value;
  let zoom = 1;
  let zoomChanges = [{ time: 0, factor: zoom }];
  let clip = null;
  let replayFrame = null;

  function announce(message) {
    if (status.textContent !== message) status.textContent = message;
  }

  function formatDuration(seconds) {
    const rounded = Math.round(seconds * 10) / 10;
    return `${rounded} ${rounded === 1 ? 'second' : 'seconds'}`;
  }

  function zoomAt(changes, time) {
    for (let i = changes.length - 1; i >= 0; i--) {
      if (changes[i].time <= time) return changes[i].factor;
    }
    return changes[0].factor;
  }

  function updateTriggerLabel() {
    const label = live.paused && !live.ended ? 'Start demo camera' : 'Tap to save replay';
    trigger.setAttribute('aria-label', label);
    if (triggerLabel) triggerLabel.textContent = label;
  }

  function reportCameraError() {
    cameraFailed = true;
    if (currentPanel === camera) announce('The sample video could not load.');
  }

  function startCamera() {
    if (!live.paused || live.ended || cameraFailed) return;

    live.play().catch((error) => {
      if (error.name === 'AbortError' || currentPanel !== camera) return;
      if (error.name === 'NotAllowedError') announce(startMessage);
      else reportCameraError();
    });
  }

  function syncCameraPlayback() {
    if (currentPanel !== camera || !inView || document.hidden) {
      live.pause();
    } else if (cameraFailed) {
      announce('The sample video could not load.');
    } else if (reduceMotion.matches && !cameraRequested) {
      live.pause();
      announce(startMessage);
    } else {
      startCamera();
    }
  }

  function showPanel(panel, focusTarget) {
    currentPanel = panel;
    for (const screen of panels) screen.hidden = screen !== panel;
    if (panel !== replay) video.pause();
    syncCameraPlayback();
    focusTarget.focus({ preventScroll: true });
  }

  function captureThumbnail() {
    const canvas = document.createElement('canvas');
    const width = live.videoWidth / zoom;
    const height = live.videoHeight / zoom;
    const context = canvas.getContext('2d');
    if (!context || !width || !height) return live.poster;

    canvas.width = 640;
    canvas.height = Math.round(canvas.width * height / width);
    try {
      context.drawImage(live, (live.videoWidth - width) / 2, (live.videoHeight - height) / 2,
        width, height, 0, 0, canvas.width, canvas.height);
      return canvas.toDataURL('image/jpeg', 0.84);
    } catch {
      return live.poster;
    }
  }

  function saveClip() {
    if (cameraFailed) {
      cameraFailed = false;
      live.load();
      zoomChanges = [{ time: 0, factor: zoom }];
    }
    if (live.paused && !live.ended) {
      cameraRequested = true;
      startCamera();
      return;
    }

    const end = live.currentTime;
    const start = Math.max(0, end - clipLengths[Number(length.value)]);
    if (live.readyState < 2 || end - start < minimumClip) {
      announce('Give the camera a moment, then tap again to save a replay.');
      return;
    }

    clip = {
      start,
      end,
      zoomChanges: [
        { time: start, factor: zoomAt(zoomChanges, start) },
        ...zoomChanges.filter(({ time }) => time > start && time <= end)
      ]
    };
    thumbnail.src = captureThumbnail();
    const clipDuration = formatDuration(end - start);
    savedDuration.textContent = clipDuration;
    showPanel(saved, play);
    announce(`Saved ${clipDuration} in the demo.`);
  }

  function syncReplay(time) {
    if (currentPanel !== replay || !clip || video.seeking) return;

    const factor = zoomAt(clip.zoomChanges, Math.min(time, clip.end));
    replay.style.setProperty('--demo-zoom', factor);

    if (time >= clip.end && !video.paused) {
      video.pause();
      if (video.currentTime > clip.end) video.currentTime = clip.end;
      offerReplay('Replay finished.');
    }
  }

  function trackReplayFrames() {
    if (replayFrame !== null || typeof video.requestVideoFrameCallback !== 'function') return;

    function onFrame(_, frame) {
      replayFrame = null;
      syncReplay(frame.mediaTime);
      if (currentPanel === replay && !video.paused) {
        replayFrame = video.requestVideoFrameCallback(onFrame);
      }
    }

    replayFrame = video.requestVideoFrameCallback(onFrame);
  }

  function offerReplay(message) {
    again.hidden = false;
    announce(message);
  }

  function playClip() {
    if (!clip) return;
    if (currentPanel !== replay) showPanel(replay, back);
    if (document.activeElement === again) back.focus({ preventScroll: true });

    again.hidden = true;
    if (video.error) video.load();
    replay.style.setProperty('--demo-zoom', zoomAt(clip.zoomChanges, clip.start));
    video.currentTime = clip.start;
    announce('Playing replay.');
    video.play().catch((error) => {
      if (error.name !== 'AbortError' && currentPanel === replay) {
        offerReplay('The replay could not play. Select Play again to retry.');
      }
    });
  }

  function closeSettings() {
    const changed = length.value !== previousLength;
    showPanel(camera, openSettings);
    if (changed) announce(`Clip length set to ${formatClipLength(clipLengths[Number(length.value)])}.`);
  }

  function closeReplay() {
    showPanel(saved, play);
    announce(`Saved ${formatDuration(clip.end - clip.start)} in the demo.`);
  }

  function nextRally() {
    live.currentTime = 0;
    zoomChanges = [{ time: 0, factor: zoom }];
    showPanel(camera, trigger);
  }

  live.muted = true;
  video.muted = true;
  live.addEventListener('playing', () => {
    updateTriggerLabel();
    if (status.textContent === startMessage) announce('');
  });
  live.addEventListener('pause', updateTriggerLabel);
  live.addEventListener('ended', updateTriggerLabel);
  live.addEventListener('error', reportCameraError);
  updateTriggerLabel();
  trigger.addEventListener('click', saveClip);

  for (const button of zoomButtons) {
    button.addEventListener('click', () => {
      const nextZoom = Number(button.dataset.demoZoom);
      if (!Number.isFinite(nextZoom) || nextZoom <= 0 || nextZoom === zoom) return;
      const time = live.currentTime;
      zoom = nextZoom;
      zoomChanges.push({ time, factor: zoom });
      demo.style.setProperty('--demo-zoom', zoom);
      for (const option of zoomButtons) option.setAttribute('aria-pressed', String(option === button));
    });
  }

  function updateDuration() {
    const label = formatClipLength(clipLengths[Number(length.value)]);
    duration.textContent = label;
    length.setAttribute('aria-valuetext', label);
  }

  length.max = clipLengths.length - 1;
  updateDuration();
  length.addEventListener('input', updateDuration);
  openSettings.addEventListener('click', () => {
    previousLength = length.value;
    showPanel(settings, length);
    announce('');
  });
  done.addEventListener('click', closeSettings);
  play.addEventListener('click', playClip);
  again.addEventListener('click', playClip);
  next.addEventListener('click', nextRally);
  back.addEventListener('click', closeReplay);
  video.addEventListener('playing', trackReplayFrames);
  video.addEventListener('timeupdate', () => syncReplay(video.currentTime));
  video.addEventListener('ended', () => {
    if (currentPanel === replay) offerReplay('Replay finished.');
  });
  video.addEventListener('error', () => {
    if (currentPanel === replay) offerReplay('The replay video could not load.');
  });
  video.addEventListener('pause', () => {
    if (replayFrame === null || !video.paused) return;
    video.cancelVideoFrameCallback(replayFrame);
    replayFrame = null;
  });
  demo.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape' || currentPanel === camera) return;
    event.preventDefault();
    if (currentPanel === replay) closeReplay();
    else if (currentPanel === settings) closeSettings();
    else nextRally();
  });

  reduceMotion.addEventListener('change', syncCameraPlayback);
  document.addEventListener('visibilitychange', () => {
    syncCameraPlayback();
    if (document.hidden && currentPanel === replay && !video.paused) {
      video.pause();
      offerReplay('Replay paused. Select Play again to restart.');
    }
  });

  demo.setAttribute('data-demo-ready', '');
  if (typeof IntersectionObserver === 'function') {
    const observer = new IntersectionObserver(([entry]) => {
      inView = entry.isIntersecting;
      syncCameraPlayback();
    });
    observer.observe(demo);
  } else {
    inView = true;
    syncCameraPlayback();
  }
}

for (const demo of document.querySelectorAll('[data-replay-demo]')) {
  initializeReplayDemo(demo);
}
