# Export Compliance Documentation - Rptr

## Encryption Declaration

### App Name: Rptr
### Version: 1.0
### Date: December 2024

## Encryption Usage Summary

**Does your app use encryption?** YES

**Type of encryption used:**
- HTTPS/TLS for secure network communication (standard iOS libraries)
- No custom encryption implementation
- No proprietary encryption algorithms

## Export Compliance Self-Classification

### 1. Primary Function
Rptr is a video streaming application that creates a local HLS server for streaming camera content over local networks.

### 2. Encryption Usage Details

The app uses encryption in the following ways:
- **Standard HTTPS/TLS**: Uses iOS built-in networking APIs
- **No Custom Encryption**: Does not implement any proprietary encryption
- **No Encrypted Content Storage**: Does not store encrypted data
- **No End-to-End Encryption**: Streams are not encrypted (HTTP only)

### 3. Export Classification

Based on the encryption usage:
- **Category**: 5D992.c (Mass market software)
- **ECCN**: 5D992.c
- **Reason**: The app only uses standard encryption provided by the iOS operating system for HTTPS connections

### 4. ITSAppUsesNonExemptEncryption

**Value in Info.plist**: `false`

**Justification**: 
The app qualifies for exemption under category 5D992.c because:
1. It only uses standard encryption protocols (HTTPS/TLS)
2. The encryption is provided by the iOS operating system
3. No proprietary encryption algorithms are implemented
4. The primary function is not related to encryption

### 5. Export Compliance Statement

This app is compliant with U.S. Export Administration Regulations (EAR). The app:
- Uses only standard encryption provided by iOS
- Does not contain any proprietary encryption technology
- Is designed for mass market distribution
- Falls under the TSU (Technology and Software - Unrestricted) exception

### 6. Annual Self-Classification Report

**Required**: YES - An annual self-classification report must be submitted to the U.S. Bureau of Industry and Security (BIS) by February 1st of each year.

**Report Details**:
- Product Name: Rptr
- ECCN: 5D992.c
- Authorization: NLR (No License Required)

### 7. Record Keeping

All export compliance documentation should be retained for 5 years as required by EAR.

## Contact Information

For export compliance questions related to this app:
[Your Contact Information]

## Updates

This document should be reviewed and updated:
- With each major version release
- When encryption implementation changes
- Annually for compliance verification

---

**Note**: This self-classification is based on the current implementation of Rptr v1.0. Any changes to encryption usage require re-evaluation of export compliance status.