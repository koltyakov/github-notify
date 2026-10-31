#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <unistd.h>

#ifndef GITHUB_NOTIFY_CREDENTIAL_SERVICE
#define GITHUB_NOTIFY_CREDENTIAL_SERVICE "com.koltyakov.github-notify.credentials.v1"
#endif

static BOOL authorizedParent(NSString **readerHash) {
    pid_t parentPID = getppid();
    if (parentPID <= 1) return NO;
    SecCodeRef ownCode = NULL;
    SecStaticCodeRef ownStatic = NULL;
    CFDictionaryRef signing = NULL;
    SecCodeRef parent = NULL;
    SecRequirementRef requirement = NULL;
    BOOL authorized = NO;
    do {
        if (SecCodeCopySelf(kSecCSDefaultFlags, &ownCode) != errSecSuccess) break;
        if (SecCodeCopyStaticCode(ownCode, kSecCSDefaultFlags, &ownStatic) != errSecSuccess) break;
        if (SecCodeCopySigningInformation(ownStatic, kSecCSSigningInformation, &signing) != errSecSuccess) break;
        NSArray *certificates = ((__bridge NSDictionary *)signing)[(__bridge NSString *)kSecCodeInfoCertificates];
        if (certificates.count == 0) break;
        NSData *unique = ((__bridge NSDictionary *)signing)[(__bridge NSString *)kSecCodeInfoUnique];
        if (![unique isKindOfClass:[NSData class]] || unique.length == 0) break;
        NSMutableString *hash = [NSMutableString string];
        const unsigned char *bytes = unique.bytes;
        for (NSUInteger i = 0; i < unique.length; i++) [hash appendFormat:@"%02x", bytes[i]];
        *readerHash = hash;
        SecCertificateRef certificate = (__bridge SecCertificateRef)certificates[0];
        NSData *data = CFBridgingRelease(SecCertificateCopyData(certificate));
        unsigned char digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
        NSMutableString *fingerprint = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [fingerprint appendFormat:@"%02x", digest[i]];
        NSString *rule = [NSString stringWithFormat:
            @"identifier \"com.koltyakov.github-notify\" and certificate leaf = H\"%@\"", fingerprint];
        if (SecRequirementCreateWithString((__bridge CFStringRef)rule, kSecCSDefaultFlags, &requirement) != errSecSuccess) break;
        NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(parentPID)};
        if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &parent) != errSecSuccess) break;
        authorized = SecCodeCheckValidity(parent, kSecCSStrictValidate, requirement) == errSecSuccess && getppid() == parentPID;
    } while (NO);
    if (requirement) CFRelease(requirement);
    if (parent) CFRelease(parent);
    if (signing) CFRelease(signing);
    if (ownStatic) CFRelease(ownStatic);
    if (ownCode) CFRelease(ownCode);
    return authorized;
}

static int reply(OSStatus status, NSString *token) {
    NSMutableDictionary *response = [@{@"status": @(status)} mutableCopy];
    if (status == errSecSuccess && token) response[@"token"] = token;
    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:NULL];
    if (!data) return 1;
    @try { [[NSFileHandle fileHandleWithStandardOutput] writeData:data]; }
    @catch (NSException *exception) { return 1; }
    return status == errSecSuccess || status == errSecItemNotFound ? 0 : 1;
}

int main(void) {
    @autoreleasepool {
        // Never expose a token to arbitrary programs that launch this helper.
        NSString *readerHash = nil;
        if (!authorizedParent(&readerHash)) return reply(errSecAuthFailed, nil);
        // A denied/locked/stale item must return an error, never open password dialogs.
        OSStatus interaction = SecKeychainSetUserInteractionAllowed(false);
        if (interaction != errSecSuccess) return reply(interaction, nil);
        unsigned char buffer[8193];
        size_t length = 0;
        while (length < sizeof(buffer)) {
            ssize_t count = read(STDIN_FILENO, buffer + length, sizeof(buffer) - length);
            if (count == 0) break;
            if (count < 0) return reply(errSecIO, nil);
            length += (size_t)count;
        }
        if (length == sizeof(buffer)) return reply(errSecParam, nil);
        NSData *input = [NSData dataWithBytes:buffer length:length];
        id decoded = [NSJSONSerialization JSONObjectWithData:input options:0 error:NULL];
        if (![decoded isKindOfClass:[NSDictionary class]]) return reply(errSecParam, nil);
        NSDictionary *request = decoded;
        NSString *operation = request[@"operation"];
        if (![operation isKindOfClass:[NSString class]]) return reply(errSecParam, nil);
        NSDictionary *query = @{
            (__bridge NSString *)kSecClass: (__bridge id)kSecClassGenericPassword,
            // A changed reader gets a fresh item, never the previous reader's
            // hash-restricted item. The user can re-save without password loops.
            (__bridge NSString *)kSecAttrService: [NSString stringWithFormat:@"%s.%@", GITHUB_NOTIFY_CREDENTIAL_SERVICE, readerHash],
            (__bridge NSString *)kSecAttrAccount: @"github-token",
        };
        if ([operation isEqualToString:@"load"]) {
            NSMutableDictionary *readQuery = [query mutableCopy];
            readQuery[(__bridge NSString *)kSecReturnData] = @YES;
            readQuery[(__bridge NSString *)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
            CFTypeRef result = NULL;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)readQuery, &result);
            NSData *data = CFBridgingRelease(result);
            if (status != errSecSuccess) return reply(status, nil);
            if (![data isKindOfClass:[NSData class]]) return reply(errSecDecode, nil);
            NSString *token = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            return token ? reply(errSecSuccess, token) : reply(errSecDecode, nil);
        }
        if (![operation isEqualToString:@"save"] || ![request[@"token"] isKindOfClass:[NSString class]]) {
            return reply(errSecParam, nil);
        }
        NSString *token = request[@"token"];
        NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length > 4096) return reply(errSecParam, nil);
        if (data.length == 0) {
            OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
            return reply(status == errSecItemNotFound ? errSecSuccess : status, nil);
        }
        NSDictionary *attributes = @{(__bridge NSString *)kSecValueData: data};
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
        if (status == errSecItemNotFound) {
            NSMutableDictionary *item = [query mutableCopy];
            [item addEntriesFromDictionary:attributes];
            item[(__bridge NSString *)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
            status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        }
        return reply(status, nil);
    }
}
