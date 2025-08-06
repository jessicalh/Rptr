# App Store Submission Checklist for Rptr

## Pre-Submission Requirements

### ✅ App Icons
- [ ] Create 1024x1024 icon (no transparency, no rounded corners)
- [ ] Generate all required icon sizes (see ICON_REQUIREMENTS.md)
- [ ] Add icons to Assets.xcassets/AppIcon.appiconset/

### ✅ App Configuration
- [x] Info.plist configured with all required keys
- [x] Bundle ID set (update in Xcode project settings)
- [x] Version number set (1.0)
- [x] Build number set (1)
- [x] Privacy usage descriptions added
- [x] Background modes configured
- [x] Launch screen created

### ✅ Legal Documents
- [x] Privacy Policy created (PRIVACY_POLICY.md)
- [ ] Host Privacy Policy online and update URL in metadata
- [ ] Terms of Service (if required)

### Screenshots Required
Create screenshots for these devices:
- [ ] iPhone 15 Pro Max (6.9") - 1320 × 2868 pixels
- [ ] iPhone 14 Plus (6.5") - 1284 × 2778 pixels  
- [ ] iPhone 14 (6.1") - 1179 × 2556 pixels
- [ ] iPhone 8 Plus (5.5") - 1242 × 2208 pixels
- [ ] iPad Pro 13" - 2064 × 2752 pixels (optional)

Screenshot suggestions:
1. Main streaming interface showing camera view
2. URL display screen with connection info
3. Browser view showing the stream
4. Permission request screen
5. Multiple devices illustration

## App Store Connect Setup

### Create App
1. [ ] Sign in to App Store Connect
2. [ ] Create new app
3. [ ] Enter app information from APP_STORE_METADATA.md
4. [ ] Upload screenshots
5. [ ] Set pricing (Free or Paid)
6. [ ] Select availability (countries)

### Build Upload
1. [ ] Archive app in Xcode (Product > Archive)
2. [ ] Validate archive
3. [ ] Upload to App Store Connect
4. [ ] Wait for processing

### App Review Information
- [ ] Add demo video URL (optional but helpful)
- [ ] Add review notes explaining local network usage
- [ ] Provide test hardware requirements if needed

## Testing Checklist

### Functionality
- [ ] Camera streaming works
- [ ] Audio streaming works
- [ ] URLs display correctly
- [ ] Browser playback works
- [ ] Permission requests handled properly
- [ ] Landscape orientation locked
- [ ] Network switching (WiFi/Cellular)

### Edge Cases
- [ ] App works without location permission
- [ ] Handles network disconnection gracefully
- [ ] Memory warnings handled
- [ ] Background/foreground transitions

### Device Testing
- [ ] iPhone (various models)
- [ ] iPad
- [ ] iOS 17.6+

## Submission

1. [ ] Submit for review
2. [ ] Monitor review status
3. [ ] Respond to any reviewer feedback
4. [ ] Prepare marketing materials for launch

## Post-Launch

- [ ] Monitor crash reports
- [ ] Check user reviews
- [ ] Plan updates based on feedback

## Important Notes

- The app requires iOS 17.6+ due to API usage
- Streaming is local network only (no internet)
- No encryption used (marked in Info.plist)
- Background audio mode enabled for streaming