**Configure notification of update and deadline to enforce the update.**
**Steps to build the *same* “5-day deadline + 00:00-09:00 restart-window” policy in **native Active Directory Group Policy** (no Intune required)**

---

## 1  Download the browser ADMX templates

| Browser            | What to grab                                                                           | Where to get it                                                                       |
| ------------------ | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| **Microsoft Edge** | `msedge.admx` + `msedge.adml` (language) and `msedgeupdate.admx` + `msedgeupdate.adml` | Microsoft Edge policy template bundle (CAB/ZIP) ([learn.microsoft.com][1])            |
| **Google Chrome**  | `chrome.admx`, `googleupdate.admx` + matching *.adml* files                            | Chrome Enterprise ADMX bundle ([chromeenterprise.google][2], [support.google.com][3]) |

Un-zip each bundle.

---

## 2  Add the templates to the Central Store

1. On a domain controller open **`\\<Domain>\SYSVOL\<Domain>\Policies\PolicyDefinitions`**.
2. Copy the **.admx** files into **PolicyDefinitions** and the **.adml** files into the matching language sub-folder (e.g. **en-US**).
3. Close/re-open **Group Policy Management Console** (GPMC); the new nodes will appear. ([winhelponline.com][4])

*(No Central Store yet?  Create **PolicyDefinitions** manually or drop the files in **C:\Windows\PolicyDefinitions** on the DC you edit from.)*

---

## 3  Create & link a GPO

> **GPMC →** right-click the OU that contains your PCs/servers → **Create a GPO in this domain**
> Name it “**Browser Updates – 5-day / 00-09**” → **Edit**.

Everything below is **Computer Configuration ▸ Policies ▸ Administrative Templates**

---

### A.  Google Chrome

| Path                                                              | Setting                                                                | Action                                               |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------- |
| **Google ▶ Google Chrome ▶ Update**                               | **Set the time period for update notifications**                       | **Enabled** → *432000000*                            |
|                                                                   | **Notify a user that a browser relaunch … is recommended or required** | **Enabled** → **Required – Show a recurring prompt** |
|                                                                   | **Set the time interval for relaunch**                                 | **Enabled** → paste JSON ↓                           |
| **Google Update ▶ Applications ▶ Update policy override default** | **Update policy override default**                                     | **Enabled** → **Always allow updates (recommended)** |

```json
{"entries":[{"start":{"hour":0,"minute":0},"duration_mins":540}]}
```

*(00 : 00 start, 540 min = 9 h)*

---

### B.  Microsoft Edge

| Path                                                                      | Setting                                                                                 | Action                                               |
| ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| **Microsoft Edge ▶ Update**                                               | **Set the time period for update notifications**                                        | **Enabled** → *432000000*                            |
|                                                                           | **Notify a user that a browser restart is recommended or required for pending updates** | **Enabled** → **Required – Show recurring prompt**   |
|                                                                           | **Set the time interval for relaunch**                                                  | **Enabled** → same JSON as above                     |
| **Microsoft Edge Update ▶ Applications ▶ Update policy override default** | **Update policy override default**                                                      | **Enabled** → **Always allow updates (recommended)** |

---

## 4  Force refresh & verify

1. On a test machine run **`gpupdate /force`** or reboot.
2. Open **`chrome://policy`** and **`edge://policy`** → **Reload policies**.
   *Expect:*

   * `RelaunchNotification = 2`
   * `RelaunchNotificationPeriod = 432000000`
   * `RelaunchWindow` shows the JSON above – **Status = OK**.

(Registry: `HKLM\SOFTWARE\Policies\Google\Chrome` and `…\Microsoft\Edge` will contain the same values.)

---

## 5  Resulting behaviour on any domain computer/server

* Updates download & install silently.
* Banner **“Restart required”** appears immediately.
* User has **5 days** to restart manually.
* If ignored, the browser auto-relaunches the next time it is open **between 00:00 and 09:00**; otherwise waits for the next window.
* Works identically for Windows 10/11 and enrolled Windows Server versions.

You now have full parity with the Intune policy using native AD Group Policy alone.

[1]: https://learn.microsoft.com/en-us/deployedge/configure-microsoft-edge?utm_source=chatgpt.com "Configure Microsoft Edge for Windows with policy settings"
[2]: https://chromeenterprise.google/download/?utm_source=chatgpt.com "Enterprise Browser Download for Windows & Mac - Chrome Enterprise"
[3]: https://support.google.com/chrome/a/answer/187202?hl=en&utm_source=chatgpt.com "Set Chrome browser policies on managed PCs - Chrome Enterprise and ..."
[4]: https://www.winhelponline.com/blog/edge-chromium-admx-group-policy-templates/?utm_source=chatgpt.com "How to Get Microsoft Edge ADMX Group Policy Templates"
