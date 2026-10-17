import type { CapacitorConfig } from '@capacitor/cli';

/**
 * iOS 壳配置。
 *
 * appId 每次做大版本验证时换一个，避免 Sideloadly 覆盖安装失效：
 * 系统会把它当成全新 App，不可能被旧版本顶替。
 *   v1: local.douyin.shell   （网页壳，能跑）
 *   v2: local.dzc.feed2      （原生 feed 验证）
 */
const config: CapacitorConfig = {
  appId: 'local.dzc.feed2',
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
      launchShowDuration: 600,
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
