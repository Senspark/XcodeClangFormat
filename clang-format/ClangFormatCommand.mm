#import "ClangFormatCommand.h"

#import <AppKit/AppKit.h>

#include <clang/Format/Format.h>

// Generates a list of offsets for ever line in the array.
static void updateOffsets(std::vector<std::size_t>& offsets,
                          NSMutableArray<NSString*>* lines) {
    offsets.clear();
    offsets.reserve([lines count] + 1);
    offsets.push_back(0);
    std::size_t offset = 0;
    for (NSString* line in lines) {
        offset += [line length];
        offsets.push_back(offset);
    }
}

NSErrorDomain errorDomain = @"ClangFormatError";

@implementation ClangFormatCommand

static NSUserDefaults* defaults = nil;

- (NSData*)getCustomStyle {
    // First, read the regular bookmark because it could've been changed by the
    // wrapper app.
    NSData* regularBookmark = [defaults dataForKey:@"regularBookmark"];
    NSURL* regularURL = nil;
    BOOL regularStale = NO;
    if (regularBookmark != nil) {
        regularURL =
            [NSURL URLByResolvingBookmarkData:regularBookmark
                                      options:NSURLBookmarkResolutionWithoutUI
                                relativeToURL:nil
                          bookmarkDataIsStale:&regularStale
                                        error:nil];
    }

    if (regularURL == nil) {
        return nil;
    }

    // Then read the security URL, which is the URL we're actually going to use
    // to access the file.
    NSData* securityBookmark = [defaults dataForKey:@"securityBookmark"];
    NSURL* securityURL = nil;
    BOOL securityStale = NO;
    if (securityBookmark != nil) {
        securityURL = [NSURL
            URLByResolvingBookmarkData:securityBookmark
                               options:
                                   NSURLBookmarkResolutionWithSecurityScope |
                                   NSURLBookmarkResolutionWithoutUI
                         relativeToURL:nil
                   bookmarkDataIsStale:&securityStale
                                 error:nil];
    }

    // Clear out the security URL if it's no longer matching the regular URL.
    if (securityStale == YES ||
        (securityURL != nil &&
         ![[securityURL path] isEqualToString:[regularURL path]])) {
        securityURL = nil;
    }

    if (securityURL == nil && regularStale == NO) {
        // Attempt to create new security URL from the regular URL to persist
        // across system reboots.
        NSError* error = nil;
        securityBookmark = [regularURL
                   bookmarkDataWithOptions:
                       NSURLBookmarkCreationWithSecurityScope |
                       NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess
            includingResourceValuesForKeys:nil
                             relativeToURL:nil
                                     error:&error];
        [defaults setObject:securityBookmark forKey:@"securityBookmark"];
        securityURL = regularURL;
    }

    if (securityURL != nil) {
        // Finally, attempt to read the .clang-format file
        NSError* error = nil;
        [securityURL startAccessingSecurityScopedResource];
        NSData* data =
            [NSData dataWithContentsOfURL:securityURL options:0 error:&error];
        [securityURL stopAccessingSecurityScopedResource];
        if (error != nil) {
            NSLog(@"Error loading from security bookmark: %@", error);
        } else if (data) {
            return data;
        }
    }

    return nil;
}

- (void)
performCommandWithInvocation:(XCSourceEditorCommandInvocation*)invocation
           completionHandler:
               (void (^)(NSError* _Nullable nilOrError))completionHandler {
    if (defaults == nil) {
        defaults =
            [[NSUserDefaults alloc] initWithSuiteName:@"XcodeClangFormat"];
    }

    NSString* style = [defaults stringForKey:@"style"];
    if (style == nil) {
        style = @"llvm";
    }

    clang::format::FormatStyle formatStyle = clang::format::getLLVMStyle();
    formatStyle.Language = clang::format::FormatStyle::LK_Cpp;
    clang::format::getPredefinedStyle("LLVM", formatStyle.Language,
                                      &formatStyle);
    if ([style isEqualToString:@"custom"]) {
        NSData* config = [self getCustomStyle];
        if (config == nil) {
            completionHandler([NSError
                errorWithDomain:errorDomain
                           code:0
                       userInfo:@{
                           NSLocalizedDescriptionKey:
                               @"Could not load custom style. Please open "
                               @"XcodeClangFormat.app"
                       }]);
        } else {
            // parse style
            // Ensure null terminated
            NSString* configString =
                [[NSString alloc] initWithData:config
                                      encoding:NSUTF8StringEncoding];
            llvm::StringRef text([configString UTF8String],
                                 [configString length]);
            auto error = clang::format::parseConfiguration(text, &formatStyle);
            if (error) {
                completionHandler([NSError
                    errorWithDomain:errorDomain
                               code:0
                           userInfo:@{
                               NSLocalizedDescriptionKey: [NSString
                                   stringWithFormat:
                                       @"Could not parse custom style: %s.",
                                       error.message().c_str()]
                           }]);
                return;
            }
        }
    } else {
        auto success = clang::format::getPredefinedStyle(
            llvm::StringRef([style cStringUsingEncoding:NSUTF8StringEncoding]),
            clang::format::FormatStyle::LanguageKind::LK_Cpp, &formatStyle);
        if (!success) {
            completionHandler([NSError
                errorWithDomain:errorDomain
                           code:0
                       userInfo:@{
                           NSLocalizedDescriptionKey: [NSString
                               stringWithFormat:
                                   @"Could not parse default style %@", style]
                       }]);
            return;
        }
    }

    NSData* buffer = [[[invocation buffer] completeBuffer]
        dataUsingEncoding:NSUTF8StringEncoding];
    NSString* bufferString =
        [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
    llvm::StringRef code([bufferString UTF8String], [bufferString length]);

    std::vector<std::size_t> offsets;
    updateOffsets(offsets, [[invocation buffer] lines]);

    std::vector<clang::tooling::Range> ranges;
    for (XCSourceTextRange* range in [[invocation buffer] selections]) {
        const std::size_t start =
            offsets[[range start].line] + [range start].column;
        const std::size_t end = offsets[[range end].line] + [range end].column;
        ranges.emplace_back(start, end - start);
    }

    // Calculated replacements and apply them to the input buffer.
    const llvm::StringRef filename("<stdin>");

    // Similar to ClangFormat.cpp
    auto replaces =
        clang::format::sortIncludes(formatStyle, code, ranges, filename);
    auto changedCode = clang::tooling::applyAllReplacements(code, replaces);
    if (!changedCode) {
        completionHandler([NSError
            errorWithDomain:errorDomain
                       code:0
                   userInfo:@{
                       NSLocalizedDescriptionKey:
                           @"Failed to sort includes."
                   }]);
        return;
    }
    ranges = clang::tooling::calculateRangesAfterReplacements(replaces, ranges);
    auto formatChanges =
        clang::format::reformat(formatStyle, *changedCode, ranges, filename);
    replaces = replaces.merge(formatChanges);
    auto result = clang::tooling::applyAllReplacements(code, replaces);
    if (!result) {
        // We could not apply the calculated replacements.
        completionHandler([NSError
            errorWithDomain:errorDomain
                       code:0
                   userInfo:@{
                       NSLocalizedDescriptionKey:
                           @"Failed to apply formatting replacements."
                   }]);
        return;
    }

    // Remove all selections before replacing the completeBuffer, otherwise we
    // get crashes when changing the buffer contents because it tries to
    // automatically update the selections, which might be out of range now.
    [[[invocation buffer] selections] removeAllObjects];

    // Update the entire text with the result we got after applying the
    // replacements.
    [[invocation buffer]
        setCompleteBuffer:[[NSString alloc]
                              initWithBytes:result->data()
                                     length:result->size()
                                   encoding:NSUTF8StringEncoding]];

    // Recalculate the line offsets.
    updateOffsets(offsets, [[invocation buffer] lines]);

    // Update the selections with the shifted code positions.
    for (auto& range : ranges) {
        const std::size_t start =
            replaces.getShiftedCodePosition(range.getOffset());
        const std::size_t end = replaces.getShiftedCodePosition(
            range.getOffset() + range.getLength());

        // In offsets, find the value that is smaller than start.
        auto start_it = std::lower_bound(offsets.begin(), offsets.end(), start);
        auto end_it = std::lower_bound(offsets.begin(), offsets.end(), end);
        if (start_it == offsets.end() || end_it == offsets.end()) {
            continue;
        }

        // We need to go one line back unless we're at the beginning of the
        // line.
        if (*start_it > start) {
            --start_it;
        }
        if (*end_it > end) {
            --end_it;
        }

        const std::size_t start_line = std::distance(offsets.begin(), start_it);
        const std::int64_t start_column =
            std::int64_t(start) - std::int64_t(*start_it);

        const std::size_t end_line = std::distance(offsets.begin(), end_it);
        const std::int64_t end_column =
            std::int64_t(end) - std::int64_t(*end_it);

        [[[invocation buffer] selections]
            addObject:[[XCSourceTextRange alloc]
                          initWithStart:XCSourceTextPositionMake(start_line,
                                                                 start_column)
                                    end:XCSourceTextPositionMake(end_line,
                                                                 end_column)]];
    }

    // If we could not recover the selection, place the cursor at the beginning
    // of the file.
    if (![[[invocation buffer] selections] count]) {
        [[[invocation buffer] selections]
            addObject:[[XCSourceTextRange alloc]
                          initWithStart:XCSourceTextPositionMake(0, 0)
                                    end:XCSourceTextPositionMake(0, 0)]];
    }

    completionHandler(nil);
}

@end
