for (const demo of document.querySelectorAll('[data-replay-demo]')) {
  const camera = demo.querySelector('[data-demo-camera]');
  const trigger = demo.querySelector('[data-demo-trigger]');
  const replay = demo.querySelector('[data-demo-replay]');
  const play = demo.querySelector('[data-demo-play]');
  const back = demo.querySelector('[data-demo-back]');

  if (!camera || !trigger || !replay || !play || !back) continue;

  function playReplay() {
    replay.classList.remove('is-animating');
    // Commit the class removal so restarting the same CSS animation works.
    replay.getBoundingClientRect();
    replay.classList.add('is-animating');
  }

  function showCamera() {
    replay.hidden = true;
    replay.classList.remove('is-animating');
    camera.hidden = false;
    trigger.focus();
  }

  trigger.addEventListener('click', () => {
    camera.hidden = true;
    replay.hidden = false;
    play.focus();
    playReplay();
  });
  play.addEventListener('click', playReplay);
  back.addEventListener('click', showCamera);
  replay.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      showCamera();
    }
  });

  trigger.hidden = false;
}
