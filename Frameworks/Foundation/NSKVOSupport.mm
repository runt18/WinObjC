//******************************************************************************
//
// Copyright (c) 2015 Microsoft Corporation. All rights reserved.
// Copyright (c) 2006-2009 Johannes Fortmann, Cocotron Contributors et al.
//
// This code is licensed under the MIT License (MIT).
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
//******************************************************************************

#import "NSKeyValueObserving-Internal.h"
#import "NSObject_NSKeyValueCoding-Internal.h"
#import <objc/objc-arc.h>

#import <Starboard/String.h>
#import <windows.h>
#import <string>
#import <tuple>

/* Exported */
// NeXT once documented the KVO Change Kind key as the string "kind" and, as such, the string literal became
// part of the public API. We have to mimic that in case an application was written under the assumption that
// they could use @"kind" to divine the change type.
NSString* const NSKeyValueChangeKindKey = @"kind";
NSString* const NSKeyValueChangeNewKey = @"NSKeyValueChangeNewKey";
NSString* const NSKeyValueChangeOldKey = @"NSKeyValueChangeOldKey";
NSString* const NSKeyValueChangeIndexesKey = @"NSKeyValueChangeIndexesKey";
NSString* const NSKeyValueChangeNotificationIsPriorKey = @"NSKeyValueChangeNotificationIsPriorKey";

#pragma region Key Observer
@implementation _NSKVOKeyObserver
- (instancetype)initWithObject:(id)object
               keypathObserver:(_NSKVOKeypathObserver*)keypathObserver
                           key:(NSString*)key
                 restOfKeypath:(NSString*)restOfKeypath
             affectedObservers:(NSArray*)affectedObservers {
    if (self = [super init]) {
        _object = object;
        _keypathObserver = [keypathObserver retain];
        _key = [key copy];
        _restOfKeypath = [restOfKeypath copy];
        _affectedObservers = [affectedObservers copy];
    }
    return self;
}

- (void)dealloc {
    [_keypathObserver release];
    [_key release];
    [_restOfKeypath release];
    [_dependentObservers release];
    [_restOfKeypathObserver release];
    [_affectedObservers release];
    [super dealloc];
}
@end
#pragma endregion

#pragma region Keypath Observer
@interface _NSKVOKeypathObserver () {
    long _changeDepth;
}
@end

@implementation _NSKVOKeypathObserver
- (instancetype)initWithObject:(id)object
                      observer:(id)observer
                       keyPath:(NSString*)keypath
                       options:(NSKeyValueObservingOptions)options
                       context:(void*)context {
    if (self = [super init]) {
        _object = object;
        _observer = observer;
        _keypath = [keypath copy];
        _options = options;
        _context = context;
    }
    return self;
}

- (void)dealloc {
    [_keypath release];
    [_pendingChange release];
    [super dealloc];
}

- (id)observer {
    return _observer;
}

- (bool)pushWillChange {
    return InterlockedIncrementNoFence(&_changeDepth) == 1;
}

- (bool)popDidChange {
    return InterlockedDecrementNoFence(&_changeDepth) == 0;
}
@end
#pragma endregion

#pragma region Object - level Observation Info
@implementation _NSKVOObservationInfo
- (instancetype)init {
    if (self = [super init]) {
        _keyObserverMap = [[NSMutableDictionary alloc] initWithCapacity:1];
    }
    return self;
}

- (void)dealloc {
    if (![self isEmpty]) {
        // We only want to flag for root observers: anything we created internally is fair game to be destroyed.
        for (NSString* key in [_keyObserverMap keyEnumerator]) {
            for (_NSKVOKeyObserver* keyObserver in [_keyObserverMap objectForKey:key]) {
                if (keyObserver.root) {
                    [NSException raise:NSInvalidArgumentException
                                format:@"Object %@ deallocated with observers still registered.", keyObserver.object];
                }
            }
        }
    }
    [_keyObserverMap release];
    [_existingDependentKeys release];
    [super dealloc];
}

- (void)pushDependencyStack {
    @synchronized(self) {
        if (_dependencyDepth == 0) {
            _existingDependentKeys = [NSMutableSet new];
        }
        ++_dependencyDepth;
    }
}

- (BOOL)lockDependentKeypath:(NSString*)keypath {
    @synchronized(self) {
        if ([_existingDependentKeys containsObject:keypath]) {
            return NO;
        }
        [_existingDependentKeys addObject:keypath];
        return YES;
    }
}

- (void)popDependencyStack {
    @synchronized(self) {
        --_dependencyDepth;
        if (_dependencyDepth == 0) {
            [_existingDependentKeys release];
            _existingDependentKeys = nil;
        }
    }
}

- (void)addObserver:(_NSKVOKeyObserver*)observer {
    NSString* key = observer.key;
    NSMutableArray* observersForKey = nil;
    @synchronized(self) {
        observersForKey = [_keyObserverMap objectForKey:key];
        if (!observersForKey) {
            observersForKey = [NSMutableArray array];
            [_keyObserverMap setObject:observersForKey forKey:key];
        }
        [observersForKey addObject:observer];
    }
}

- (void)removeObserver:(_NSKVOKeyObserver*)observer {
    @synchronized(self) {
        NSString* key = observer.key;
        NSMutableArray* observersForKey = [_keyObserverMap objectForKey:key];
        [observersForKey removeObject:observer];
        if (observersForKey.count == 0) {
            [_keyObserverMap removeObjectForKey:key];
        }
    }
}

- (NSArray*)observersForKey:(NSString*)key {
    @synchronized(self) {
        // This is a copy because most downstream consumers will mutate the original list.
        return [[[_keyObserverMap objectForKey:key] copy] autorelease];
    }
}

- (bool)isEmpty {
    @synchronized(self) {
        return _keyObserverMap.count == 0;
    }
}
@end

static _NSKVOObservationInfo* _createObservationInfoForObject(id object) {
    _NSKVOObservationInfo* observationInfo = [_NSKVOObservationInfo new];
    [object setObservationInfo:observationInfo];
    [observationInfo release];
    return observationInfo;
}
#pragma endregion

#pragma region Observer / Key Registration
static _NSKVOKeyObserver* _addKeypathObserver(id object,
                                              NSString* keypath,
                                              _NSKVOKeypathObserver* keyPathObserver,
                                              NSArray* affectedObservers);
static void _removeKeyObserver(_NSKVOKeyObserver* keyObserver);

// Private helper that backs the default implementation of keyPathsForValuesAffectingValueForKey:
// Returns nil instead of constructing an empty set if no keyPaths are found
// Also used internally as a minor optimization, to avoid constructing an empty set when it is not needed
static NSSet* _keyPathsForValuesAffectingValueForKey(Class self, NSString* key) {
    // This function can be a KVO bottleneck, so it will prefer to use c string manipulation when safe
    NSUInteger keyLength = key.length;
    if (keyLength > 0) {
        static const size_t sc_bufferSize = 128;
        static const size_t sc_prefixLength = strlen("keyPathsForValuesAffecting"); // 26

        // max length of a key that can guaranteed fit in the char buffer,
        // even if UTF16->UTF8 conversion causes length to double, or a null terminator is needed
        static const size_t sc_safeKeyLength = (sc_bufferSize - sc_prefixLength) / 2 - 1; // 50

        const char* rawKey = [key UTF8String];
        SEL sel;

        if (keyLength <= sc_safeKeyLength) {
            // fast path using c string manipulation, will cover most cases, as most keyPaths are short
            char selectorName[sc_bufferSize] = "keyPathsForValuesAffecting"; // 26 chars
            selectorName[sc_prefixLength] = toupper(rawKey[0]);
            strcpy_s(&selectorName[sc_prefixLength + 1], sc_bufferSize - sc_prefixLength - 1, &rawKey[1]);
            sel = sel_registerName(selectorName);

        } else {
            // guaranteed path
            std::string selectorName("keyPathsForValuesAffecting");
            selectorName += toupper(rawKey[0]);
            selectorName += &rawKey[1];
            sel = sel_registerName(selectorName.data());
        }

        if ([self respondsToSelector:sel]) {
            return [self performSelector:sel];
        }
    }
    return nil;
}

// Add all observers with declared dependencies on this one:
// * All keypaths that could trigger a change (keypaths for values affecting us).
// * The head of the remaining keypath.
static void _addNestedObserversAndOptionallyDependents(_NSKVOKeyObserver* keyObserver, bool dependents) {
    id object = keyObserver.object;
    NSString* key = keyObserver.key;
    _NSKVOKeypathObserver* keypathObserver = keyObserver.keypathObserver;
    _NSKVOObservationInfo* observationInfo =
        (__bridge _NSKVOObservationInfo*)[object observationInfo] ?: _createObservationInfoForObject(object);

    // Aggregate all keys whose values will affect us.
    if (dependents) {
        NSSet* valueInfluencingKeys = _keyPathsForValuesAffectingValueForKey([object class], key);
        if (valueInfluencingKeys.count > 0) {
            // affectedKeyObservers is the list of observers that must be notified of changes.
            // If we have descendants, we have to add ourselves to the growing list of affected keys.
            // If not, we must pass it along unmodified.
            // (This is a minor optimization: we don't need to signal for our own reconstruction
            //  if we have no subpath observers.)
            NSArray* affectedKeyObservers =
                (keyObserver.restOfKeypath ?
                     [keyObserver.affectedObservers arrayByAddingObject:keyObserver] ?: [NSArray arrayWithObject:keyObserver] :
                     keyObserver.affectedObservers);

            [observationInfo pushDependencyStack];
            [observationInfo lockDependentKeypath:keyObserver.key]; // Don't allow our own key to be recreated.

            NSMutableArray* dependentObservers = [NSMutableArray arrayWithCapacity:[valueInfluencingKeys count]];
            for (NSString* dependentKeypath in valueInfluencingKeys) {
                if ([observationInfo lockDependentKeypath:dependentKeypath]) {
                    _NSKVOKeyObserver* dependentObserver =
                        _addKeypathObserver(object, dependentKeypath, keypathObserver, affectedKeyObservers);
                    if (dependentObserver) {
                        [dependentObservers addObject:dependentObserver];
                    }
                }
            }
            keyObserver.dependentObservers = dependentObservers;

            [observationInfo popDependencyStack];
        }
    } else {
        // Our dependents still exist, but their leaves have been pruned. Give them the same treatment as us: recreate their leaves.
        for (_NSKVOKeyObserver* dependentKeyObserver in keyObserver.dependentObservers) {
            _addNestedObserversAndOptionallyDependents(dependentKeyObserver, false);
        }
    }

    // If restOfKeypath is non-nil, we have to chain on further observers.
    if (keyObserver.restOfKeypath) {
        keyObserver.restOfKeypathObserver =
            _addKeypathObserver([object valueForKey:key], keyObserver.restOfKeypath, keypathObserver, keyObserver.affectedObservers);
    }

    // Back-propagation of changes.
    // This is where a value-affecting key signals to its dependent that it should be reconstructed.
    for (_NSKVOKeyObserver* affectedObserver in keyObserver.affectedObservers) {
        if (!affectedObserver.restOfKeypathObserver) {
            affectedObserver.restOfKeypathObserver = _addKeypathObserver([affectedObserver.object valueForKey:affectedObserver.key],
                                                                         affectedObserver.restOfKeypath,
                                                                         affectedObserver.keypathObserver,
                                                                         affectedObserver.affectedObservers);
        }
    }
}

static void _addKeyObserver(_NSKVOKeyObserver* keyObserver) {
    id object = keyObserver.object;
    _NSKVOEnsureKeyWillNotify(object, keyObserver.key);
    _NSKVOObservationInfo* observationInfo =
        (__bridge _NSKVOObservationInfo*)[object observationInfo] ?: _createObservationInfoForObject(object);
    [observationInfo addObserver:keyObserver];
}

static _NSKVOKeyObserver* _addKeypathObserver(id object,
                                              NSString* keypath,
                                              _NSKVOKeypathObserver* keyPathObserver,
                                              NSArray* affectedObservers) {
    if (!object) {
        return nil;
    }
    NSString* key = nil;
    NSString* restOfKeypath;
    key = _NSKVCSplitKeypath(keypath, &restOfKeypath);

    _NSKVOKeyObserver* keyObserver = [[[_NSKVOKeyObserver alloc] initWithObject:object
                                                                keypathObserver:keyPathObserver
                                                                            key:key
                                                                  restOfKeypath:restOfKeypath
                                                              affectedObservers:affectedObservers] autorelease];

    if (object) {
        _addNestedObserversAndOptionallyDependents(keyObserver, true);
        _addKeyObserver(keyObserver);
    }

    return keyObserver;
}
#pragma endregion

#pragma region Observer / Key Deregistration
static void _removeNestedObserversAndOptionallyDependents(_NSKVOKeyObserver* keyObserver, bool dependents) {
    if (keyObserver.restOfKeypathObserver) {
        // Destroy the subpath observer recursively.
        _removeKeyObserver(keyObserver.restOfKeypathObserver);
        keyObserver.restOfKeypathObserver = nil;
    }

    if (dependents) {
        // Destroy each observer whose value affects ours, recursively.
        for (_NSKVOKeyObserver* dependentKeyObserver in keyObserver.dependentObservers) {
            _removeKeyObserver(dependentKeyObserver);
        }

        keyObserver.dependentObservers = nil;
    } else {
        // Our dependents must be kept alive but pruned.
        for (_NSKVOKeyObserver* dependentKeyObserver in keyObserver.dependentObservers) {
            _removeNestedObserversAndOptionallyDependents(dependentKeyObserver, false);
        }
    }

    if (keyObserver.affectedObservers) {
        // Begin to reconstruct each observer that depends on our key's value (triggers in _addDependentAndNestedObservers).
        for (_NSKVOKeyObserver* affectedObserver in keyObserver.affectedObservers) {
            _removeKeyObserver(affectedObserver.restOfKeypathObserver);
            affectedObserver.restOfKeypathObserver = nil;
        }
    }
}

static void _removeKeyObserver(_NSKVOKeyObserver* keyObserver) {
    if (!keyObserver) {
        return;
    }

    _NSKVOObservationInfo* observationInfo = (_NSKVOObservationInfo*)[keyObserver.object observationInfo];

    [keyObserver retain];

    _removeNestedObserversAndOptionallyDependents(keyObserver, true);

    // These are removed elsewhere; we're probably being cleared as a result of their deletion anyway.
    keyObserver.affectedObservers = nil;

    [observationInfo removeObserver:keyObserver];

    [keyObserver release];
}

static void _removeKeypathObserver(id object, NSString* keypath, id observer, void* context) {
    NSString* key = nil;
    NSString* restOfKeypath;
    key = _NSKVCSplitKeypath(keypath, &restOfKeypath);

    _NSKVOObservationInfo* observationInfo = (_NSKVOObservationInfo*)[object observationInfo];
    for (_NSKVOKeyObserver* keyObserver in [observationInfo observersForKey:key]) {
        _NSKVOKeypathObserver* keypathObserver = keyObserver.keypathObserver;
        if (keypathObserver.observer == observer && keypathObserver.object == object && [keypathObserver.keypath isEqual:keypath] &&
            (!context || keypathObserver.context == context)) {
            _removeKeyObserver(keyObserver);
            return;
        }
    }

    [NSException
         raise:NSInvalidArgumentException
        format:@"Cannot remove observer %@ for keypath \"%@\" from %@ as it is not a registered observer.", observer, keypath, object];
}
#pragma endregion

#pragma region KVO Core Implementation - NSObject category

@implementation NSObject (NSKeyValueObserving)
/**
@Status Interoperable
*/
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary<NSString*, id>*)change context:(void*)context {
    [NSException raise:NSInternalInconsistencyException
                format:@"A key-value observation notification fired, but nobody responded to it: object %@, keypath %@, change %@.",
                       object,
                       keyPath,
                       change];
}

static void* s_kvoObservationInfoAssociationKey; // has no value; pointer used as an association key.

/**
@Status Interoperable
*/
- (void*)observationInfo {
    return (__bridge void*)objc_getAssociatedObject(self, &s_kvoObservationInfoAssociationKey);
}

/**
@Status Interoperable
*/
- (void)setObservationInfo:(void*)observationInfo {
    objc_setAssociatedObject(self, &s_kvoObservationInfoAssociationKey, (__bridge id)observationInfo, OBJC_ASSOCIATION_RETAIN);
}

/**
@Status Interoperable
*/
+ (BOOL)automaticallyNotifiesObserversForKey:(NSString*)key {
    if ([key length] > 0) {
        const char* rawKey = [key UTF8String];
        auto selectorName = woc::string::format("automaticallyNotifiesObserversOf%c%s", toupper(rawKey[0]), rawKey + 1);
        SEL sel = sel_registerName(selectorName.c_str());
        if ([self respondsToSelector:sel]) {
            return ((BOOL(*)(id, SEL))objc_msgSend)(self, sel);
        }
    }
    return YES;
}

/**
@Status Interoperable
*/
+ (NSSet*)keyPathsForValuesAffectingValueForKey:(NSString*)key {
    NSSet* ret = _keyPathsForValuesAffectingValueForKey(self, key);
    return ret ? ret : [NSSet set];
}

/**
@Status Interoperable
*/
- (void)addObserver:(id)observer forKeyPath:(NSString*)keyPath options:(NSKeyValueObservingOptions)options context:(void*)context {
    _NSKVOKeypathObserver* keypathObserver =
        [[[_NSKVOKeypathObserver alloc] initWithObject:self observer:observer keyPath:keyPath options:options context:context] autorelease];
    _NSKVOKeyObserver* rootObserver = _addKeypathObserver(self, keyPath, keypathObserver, nil);
    rootObserver.root = true;

    if ((options & NSKeyValueObservingOptionInitial)) {
        NSMutableDictionary* change =
            [NSMutableDictionary dictionaryWithObjectsAndKeys:@(NSKeyValueChangeSetting), NSKeyValueChangeKindKey, nil];

        if ((options & NSKeyValueObservingOptionNew)) {
            id newValue = [self valueForKeyPath:keyPath] ?: [NSNull null];
            [change setObject:newValue forKey:NSKeyValueChangeNewKey];
        }

        [observer observeValueForKeyPath:keyPath ofObject:self change:change context:context];
    }
}

/**
@Status Interoperable
*/
- (void)removeObserver:(id)observer forKeyPath:(NSString*)keyPath context:(void*)context {
    _removeKeypathObserver(self, keyPath, observer, context);
    _NSKVOObservationInfo* observationInfo = (__bridge _NSKVOObservationInfo*)[self observationInfo];
    if ([observationInfo isEmpty]) {
        [self setObservationInfo:nullptr];
    }
}

/**
@Status Interoperable
*/
- (void)removeObserver:(id)observer forKeyPath:(NSString*)keyPath {
    [self removeObserver:observer forKeyPath:keyPath context:NULL];
}

static id _valueForPendingChange(
    id notifyingObject, NSString* key, id rootObject, NSString* keypath, _NSKVOKeyObserver* keyObserver, NSDictionary* pendingChange) {
    id value = nil;
    NSIndexSet* indexes = [pendingChange objectForKey:NSKeyValueChangeIndexesKey];
    if (!indexes) {
        value = [rootObject valueForKeyPath:keypath];
    } else {
        NSArray* collection = [notifyingObject valueForKey:key];
        NSString* restOfKeypath = keyObserver.restOfKeypath;
        value = restOfKeypath.length > 0 ? [collection valueForKeyPath:restOfKeypath] : collection;
        if ([value respondsToSelector:@selector(objectsAtIndexes:)]) {
            value = [value objectsAtIndexes:indexes];
        }
    }

    if (!value) {
        value = [NSNull null];
    }
    return value;
}

static void _dispatchWillChange(id notifyingObject, NSString* key, NSMutableDictionary* change) {
    _NSKVOObservationInfo* observationInfo = (__bridge _NSKVOObservationInfo*)[notifyingObject observationInfo];

    NSUInteger changeKind = [change[NSKeyValueChangeKindKey] unsignedIntegerValue];
    for (_NSKVOKeyObserver* keyObserver in [observationInfo observersForKey:key]) {
        _NSKVOKeypathObserver* keypathObserver = keyObserver.keypathObserver;

        if (![keypathObserver pushWillChange]) {
            // Skip any keypaths that are in the process of changing.
            continue;
        } else {
            NSKeyValueObservingOptions options = keypathObserver.options;
            id rootObject = keypathObserver.object;
            id observer = keypathObserver.observer;
            NSString* keypath = keypathObserver.keypath;
            void* context = keypathObserver.context;

            // The reference platform does not support to-many mutations on nested keypaths.
            // We have to treat them as to-one mutations to support aggregate functions.
            if (changeKind != NSKeyValueChangeSetting && keyObserver.restOfKeypathObserver) {
                // This only needs to be done in willChange because didChange derives from the existing changeset.
                change[NSKeyValueChangeKindKey] = @(changeKind = NSKeyValueChangeSetting);
                [change removeObjectForKey:NSKeyValueChangeIndexesKey];
            }

            if ((options & NSKeyValueObservingOptionOld) && changeKind != NSKeyValueChangeInsertion) {
                // For to-many mutations, we can't get the old values at indexes that have not yet been inserted.
                id oldValue = _valueForPendingChange(notifyingObject, key, rootObject, keypath, keyObserver, change);
                [change setObject:oldValue forKey:NSKeyValueChangeOldKey];

                // VSO 5051216: Implement set mutation notifications.
            }

            if ((options & NSKeyValueObservingOptionPrior)) {
                [change setObject:@(YES) forKey:NSKeyValueChangeNotificationIsPriorKey];
                [observer observeValueForKeyPath:keypath ofObject:rootObject change:change context:context];
                [change removeObjectForKey:NSKeyValueChangeNotificationIsPriorKey];
            }

            keypathObserver.pendingChange = change;
        }

        // This must happen regardless of whether we are currently notifying.
        _removeNestedObserversAndOptionallyDependents(keyObserver, false);
    }
}

/**
@Status Interoperable
*/
- (void)willChangeValueForKey:(NSString*)key {
    if (![self observationInfo]) {
        return;
    }
    _dispatchWillChange(self, key, [NSMutableDictionary dictionaryWithObject:@(NSKeyValueChangeSetting) forKey:NSKeyValueChangeKindKey]);
}

static void _dispatchDidChange(id notifyingObject, NSString* key) {
    _NSKVOObservationInfo* observationInfo = (__bridge _NSKVOObservationInfo*)[notifyingObject observationInfo];
    NSArray<_NSKVOKeyObserver*>* observers = [observationInfo observersForKey:key];
    NSMutableDictionary* keypathValueCache = [NSMutableDictionary dictionaryWithCapacity:[observers count]];
    for (_NSKVOKeyObserver* keyObserver in [observers reverseObjectEnumerator]) {
        _NSKVOKeypathObserver* keypathObserver = keyObserver.keypathObserver;

        // This must happen regardless of whether we are currently notifying.
        _addNestedObserversAndOptionallyDependents(keyObserver, false);

        if (![keypathObserver popDidChange]) {
            // Skip any keypaths that are in the process of changing.
            continue;
        }

        NSKeyValueObservingOptions options = keypathObserver.options;
        id rootObject = keypathObserver.object;
        id observer = keypathObserver.observer;
        NSString* keypath = keypathObserver.keypath;
        NSMutableDictionary* change = keypathObserver.pendingChange;
        void* context = keypathObserver.context;

        if ((options & NSKeyValueObservingOptionNew) && [change[NSKeyValueChangeKindKey] integerValue] != NSKeyValueChangeRemoval) {
            // For to-many mutations, we can't get the new values at indexes that have been deleted.
            id newValue = [keypathValueCache objectForKey:keypath];
            if (!newValue) {
                newValue = _valueForPendingChange(notifyingObject, key, rootObject, keypath, keyObserver, change);
                [keypathValueCache setObject:newValue forKey:keypath];
            }
            [change setObject:newValue forKey:NSKeyValueChangeNewKey];

            // VSO 5051216: Implement set mutation notifications.
        }

        [observer observeValueForKeyPath:keypath ofObject:rootObject change:change context:context];

        keypathObserver.pendingChange = nil;
    }
}

/**
@Status Interoperable
*/
- (void)didChangeValueForKey:(NSString*)key {
    if (![self observationInfo]) {
        return;
    }
    _dispatchDidChange(self, key);
}

/**
@Status Interoperable
*/
- (void)willChange:(NSKeyValueChange)change valuesAtIndexes:(NSIndexSet*)indexes forKey:(NSString*)key {
    if (![self observationInfo]) {
        return;
    }
    _dispatchWillChange(self,
                        key,
                        [NSMutableDictionary
                            dictionaryWithObjectsAndKeys:@(change), NSKeyValueChangeKindKey, indexes, NSKeyValueChangeIndexesKey, nil]);
}

/**
@Status Interoperable
*/
- (void)didChange:(NSKeyValueChange)change valuesAtIndexes:(NSIndexSet*)indexes forKey:(NSString*)key {
    if (![self observationInfo]) {
        return;
    }
    _dispatchDidChange(self, key);
}

/**
 @Status Stub
*/
- (void)willChangeValueForKey:(NSString*)key withSetMutation:(NSKeyValueSetMutationKind)mutationKind usingObjects:(NSSet*)options {
    UNIMPLEMENTED();
}

/**
 @Status Stub
*/
- (void)didChangeValueForKey:(NSString*)key withSetMutation:(NSKeyValueSetMutationKind)mutationKind usingObjects:(NSSet*)options {
    UNIMPLEMENTED();
}
@end
#pragma endregion
