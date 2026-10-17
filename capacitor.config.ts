import type { CapacitorConfig } from '@capacitor/cli';

/**
 * iOS 壳配置。
 *
 * 关键点：
 *   · iosScheme = 'capacitor'：本站页面跑在 capacitor://localhost，
 *     接口请求要走绝对地址（native-bridge.js 里的 serverBase）。
 *   · 允许 cors / 明文：走 Tailscale 时是 https，走局域网时是 http。
 *   · limitsNavigationsToAppBoundDomains = false：否则首次填服务器地址后 reload 会被拦。
 */
const config: CapacitorConfig = {
  appId: 'local.douyin.shell',
  appName: '本地视频',
  webDir: 'www',
  ios: {
    contentInset: 'never',
    scrollEnabled: false,
    backgroundColor: '#000000',
    limitsNavigationsToAppBoundDomains: false,
  },
  server: {
    iosScheme: 'capacitor',
    cleartext: true,
    allowNavigation: ['*'],
  },
  plugins: {
    SplashScreen: {
      launchAutoHide: true,
      launchShowDuration: 800,
      backgroundColor: '#000000FF',
      showSpinner: false,
    },
    StatusBar: {
      style: 'DARK',
      backgroundColor: '#000000',
      overlaysWebView: true,
    },
  },
};

export default config;
