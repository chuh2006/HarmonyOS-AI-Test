/** Thin safe wrappers around prompt actions (deprecated globals may throw). */
import { promptAction } from '@kit.ArkUI';

export function showToast(message: string): void {
  try {
    promptAction.showToast({ message: message });
  } catch (e) {
    // toast failures must never break the app
  }
}

export function confirmDialog(title: string, message: string, confirmText: string): Promise<boolean> {
  try {
    return promptAction.showDialog({
      title: title,
      message: message,
      buttons: [
        { text: '取消', color: '#5F5F6B' },
        { text: confirmText, color: '#D6453F' }
      ]
    }).then((res) => {
      return res.index === 1;
    }).catch(() => {
      return false;
    });
  } catch (e) {
    return Promise.resolve(false);
  }
}
