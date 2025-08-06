# App Store Submission Final Checklist - Rptr

## Pre-Submission Requirements ✅

### Developer Account & Certificates
- [ ] Apple Developer Account ($99/year)
- [ ] Valid distribution certificate
- [ ] App Store provisioning profile
- [ ] Push notification certificates (if needed)

### Project Configuration
- [x] Bundle Identifier set correctly
- [x] Version number: 1.0
- [x] Build number: 1
- [x] Deployment target: iOS 17.6
- [x] All required device capabilities listed
- [x] Landscape orientation properly configured

## Required Files Status

### ✅ COMPLETED
1. **Info.plist** - All required keys added:
   - CFBundleExecutable
   - CFBundlePackageType 
   - CFBundleDevelopmentRegion
   - MinimumOSVersion
   - UIMainStoryboardFile
   - All privacy usage descriptions
   - Export compliance flag

2. **App Icons** - All sizes created:
   - 1024x1024 App Store icon
   - All required app icon sizes
   - Proper naming and format

3. **Launch Screen**
   - LaunchScreen.storyboard present

4. **Documentation Created**:
   - Privacy Policy (PRIVACY_POLICY.md)
   - Terms of Service (TERMS_OF_SERVICE.md)
   - Export Compliance (EXPORT_COMPLIANCE.md)
   - App Store Metadata (APP_STORE_CONNECT_METADATA.json)

### ❌ TO DO BEFORE SUBMISSION

1. **Screenshots** (REQUIRED)
   - [ ] Create 6.9" iPhone screenshots (1320 x 2868)
   - [ ] Create 13" iPad screenshots (2064 x 2752)
   - [ ] Remove status bars from all screenshots
   - [ ] Save as JPEG or PNG without transparency

2. **Online Hosting** (REQUIRED)
   - [ ] Host Privacy Policy online
   - [ ] Host Terms of Service online
   - [ ] Create Support URL/page
   - [ ] Update all URLs in metadata

3. **App Store Connect Setup**
   - [ ] Create app in App Store Connect
   - [ ] Set correct bundle ID
   - [ ] Upload screenshots
   - [ ] Fill in all metadata from JSON file
   - [ ] Set pricing (Free)
   - [ ] Select categories
   - [ ] Configure territories

4. **Final Testing**
   - [ ] Test on physical device
   - [ ] Verify all permissions work
   - [ ] Test streaming functionality
   - [ ] Check memory usage
   - [ ] Verify no crashes

## Submission Process

1. **Archive in Xcode**
   ```
   Product > Archive
   ```

2. **Validate Archive**
   ```
   Window > Organizer > Validate App
   ```

3. **Upload to App Store Connect**
   ```
   Window > Organizer > Distribute App
   ```

4. **Configure in App Store Connect**
   - Add build to version
   - Complete all metadata
   - Upload screenshots
   - Submit for review

## Important URLs to Update

Replace these placeholder URLs in the metadata:
- Privacy Policy: `https://github.com/your-username/rptr/blob/main/PRIVACY_POLICY.md`
- Terms of Service: `https://github.com/your-username/rptr/blob/main/TERMS_OF_SERVICE.md`
- Support URL: `https://github.com/your-username/rptr/wiki/support`
- Marketing URL: `https://github.com/your-username/rptr`

## Review Guidelines Compliance

Ensure compliance with:
- [x] No objectionable content
- [x] Privacy policy present
- [x] Accurate app description
- [x] Functional app with clear purpose
- [x] No placeholder content
- [x] Proper permission usage
- [x] No private APIs used

## Post-Submission

- Monitor App Store Connect for review status
- Respond promptly to any reviewer feedback
- Typical review time: 24-48 hours
- Be prepared to provide demo instructions

## Notes

- Current Bundle ID in project: `$(PRODUCT_BUNDLE_IDENTIFIER)`
- This needs to be set to actual value (e.g., `com.yourcompany.rptr`)
- All URLs need to be updated to actual hosted locations
- Screenshots are the only major missing requirement