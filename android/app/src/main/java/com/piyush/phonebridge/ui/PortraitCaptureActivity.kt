package com.piyush.phonebridge.ui

import com.journeyapps.barcodescanner.CaptureActivity

// The zxing-embedded scanner ships locked to landscape; declaring this
// subclass with android:screenOrientation="portrait" in the manifest is the
// supported way to scan upright.
class PortraitCaptureActivity : CaptureActivity()
