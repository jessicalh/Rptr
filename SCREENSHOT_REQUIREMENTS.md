# App Store Screenshot Requirements

## Required Screenshots (Mandatory)

### 1. 6.9" Display (iPhone 16 Pro Max, iPhone 15 Pro Max)
- **Size**: 1320 x 2868 pixels
- **Status**: ❌ REQUIRED - NOT CREATED
- **Device Examples**: iPhone 16 Pro Max, iPhone 15 Pro Max

### 2. 13" Display (iPad Pro)
- **Size**: 2064 x 2752 pixels  
- **Status**: ❌ REQUIRED - NOT CREATED
- **Device Examples**: iPad Pro 13-inch

## Screenshot Content Guidelines

### Recommended Screenshots (5-8 total):
1. **Main streaming interface** - Show the app actively streaming with preview
2. **URL display** - Show the URLs generated for accessing the stream
3. **Permission requests** - Show the clean permission request UI
4. **Web browser view** - Show how the stream appears in a browser
5. **Settings/Controls** - Show any controls or settings available
6. **Location overlay** - Show the optional location display feature
7. **Network status** - Show connected clients or streaming status
8. **Dark mode** - Show the app in dark mode (if applicable)

### Screenshot Best Practices:
- No status bars (hide them in screenshots)
- Use actual app UI, not mockups
- Ensure text is readable
- Show the app in actual use
- Include diverse content that represents key features
- Consider adding text overlays to highlight features
- Use high-quality, well-lit images

## How to Create Screenshots

### Method 1: Xcode Simulator
1. Run app in Simulator with correct device
2. Set up the desired screen
3. Press Cmd+S to save screenshot
4. Screenshots saved to Desktop

### Method 2: Physical Device
1. Run app on device
2. Press Side Button + Volume Up
3. Transfer screenshots to Mac
4. Use image editor to remove status bar

### Method 3: Xcode Screenshot Tool
1. In Xcode, go to Window > Devices and Simulators
2. Select your device
3. Click "Take Screenshot"

## Screenshot Editing Tips

1. **Remove Status Bar**:
   - Crop exactly 132 pixels from top for iPhone
   - Crop exactly 40-44 pixels from top for iPad

2. **File Format**:
   - Save as JPEG or PNG
   - RGB color space
   - No transparency/alpha channel

3. **File Naming Convention**:
   ```
   iphone69_1_main_interface.png
   iphone69_2_streaming_urls.png
   ipad13_1_main_interface.png
   ipad13_2_landscape_view.png
   ```

## Localization

If supporting multiple languages, create localized screenshots for each:
- English (required)
- Additional languages (optional)

## Upload Process

1. Log in to App Store Connect
2. Select your app
3. Go to "App Store" tab
4. Select version
5. Scroll to "App Previews and Screenshots"
6. Drag and drop screenshots in correct device categories
7. Arrange in desired order (first screenshot is most important)

## Current Status
- [ ] Create 6.9" iPhone screenshots (REQUIRED)
- [ ] Create 13" iPad screenshots (REQUIRED)
- [ ] Create optional additional device screenshots
- [ ] Prepare text overlays if needed
- [ ] Test screenshots in App Store Connect