{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
  },
  onEntrypointLoaded: async function (engineInitializer) {
    const statusEl = document.getElementById('loading-status');
    if (statusEl) {
      statusEl.textContent = 'جاري تجهيز الطاولة...';
    }
    const appRunner = await engineInitializer.initializeEngine({
      canvasKitBaseUrl: 'canvaskit/',
    });
    const loader = document.getElementById('loading');
    if (loader) {
      loader.remove();
    }
    await appRunner.runApp();
  },
});
