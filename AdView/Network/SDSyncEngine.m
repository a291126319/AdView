//
//  SDSyncEngine.m
//  SignificantDates
//
//  Created by Chris Wagner on 7/1/12.
//

#import "SDSyncEngine.h"
#import "SDAFParseAPIClient.h"
#import "AFHTTPRequestOperation.h"
#import "NSManagedObject+JSON.h"
#import "AdViewer-Swift.h"
#import <CoreData/CoreData.h>
NSString * const kSDSyncEngineInitialCompleteKey = @"SDSyncEngineInitialSyncCompleted";
NSString * const kSDSyncEngineSyncCompletedNotificationName = @"SDSyncEngineSyncCompleted";

@interface SDSyncEngine ()

@property (nonatomic, strong) NSMutableArray *registeredClassesToSync;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;

@end

@implementation SDSyncEngine

@synthesize syncInProgress = _syncInProgress;

@synthesize registeredClassesToSync = _registeredClassesToSync;
@synthesize dateFormatter = _dateFormatter;

+ (SDSyncEngine *)sharedEngine {
    static SDSyncEngine *sharedEngine = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedEngine = [[SDSyncEngine alloc] init];
    });
    
    return sharedEngine;
}

- (void)registerNSManagedObjectClassToSync:(Class)aClass {
    if (!self.registeredClassesToSync) {
        self.registeredClassesToSync = [NSMutableArray array];
    }
    
    if ([aClass isSubclassOfClass:[NSManagedObject class]]) {        
        if (![self.registeredClassesToSync containsObject:NSStringFromClass(aClass)]) {
            [self.registeredClassesToSync addObject:NSStringFromClass(aClass)];
        } else {
            NSLog(@"Unable to register %@ as it is already registered", NSStringFromClass(aClass));
        }
    } else {
        NSLog(@"Unable to register %@ as it is not a subclass of NSManagedObject", NSStringFromClass(aClass));
    }
}
- (void)saveContext {
    [self executeSyncCompletedOperations];
    }

- (void)startSync {
    if (!self.syncInProgress) {
        [self willChangeValueForKey:@"syncInProgress"];
        _syncInProgress = YES;
        [self didChangeValueForKey:@"syncInProgress"];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            [self downloadDataForRegisteredObjects:YES toDeleteLocalRecords:NO];
        });
    }
/*
    NSManagedObjectContext *managedObjectContext = [[SDCoreDataController sharedInstance] backgroundManagedObjectContext];
    NSFetchRequest* cdrequest = [NSFetchRequest fetchRequestWithEntityName:@"Holiday"]; // iOS 5 method
    cdrequest.returnsObjectsAsFaults = NO;
    NSError * error;
    NSArray *results = [managedObjectContext executeFetchRequest:cdrequest error:&error];
*/
}

- (void)executeSyncCompletedOperations {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setInitialSyncCompleted];
        NSError *error = nil;
        [[SDCoreDataController sharedInstance] saveBackgroundContext];
        if (error) {
            NSLog(@"Error saving background context after creating objects on server: %@", error);
        }
        
        [[SDCoreDataController sharedInstance] saveMasterContext];
        [[NSNotificationCenter defaultCenter] 
         postNotificationName:kSDSyncEngineSyncCompletedNotificationName 
         object:nil];
        [self willChangeValueForKey:@"syncInProgress"];
        _syncInProgress = NO;
        [self didChangeValueForKey:@"syncInProgress"];
    });
}


- (BOOL)initialSyncComplete {
    return [[[NSUserDefaults standardUserDefaults] valueForKey:kSDSyncEngineInitialCompleteKey] boolValue];
}

- (void)setInitialSyncCompleted {
    [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:YES] forKey:kSDSyncEngineInitialCompleteKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSDate *)mostRecentUpdatedAtDateForEntityWithName:(NSString *)entityName {
    __block NSDate *date = nil;
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entityName];
    [request setSortDescriptors:[NSArray arrayWithObject:
                                 [NSSortDescriptor sortDescriptorWithKey:@"updatedAt" ascending:NO]]];
    [request setFetchLimit:1];
    [[[SDCoreDataController sharedInstance] backgroundManagedObjectContext] performBlockAndWait:^{
        NSError *error = nil;
        NSArray *results = [[[SDCoreDataController sharedInstance] backgroundManagedObjectContext] executeFetchRequest:request error:&error];
        if ([results lastObject])   {
            date = [[results lastObject] valueForKey:@"updatedAt"];
        }
    }];
    
    return date;
}

- (void)downloadDataForRegisteredObjects:(BOOL)useUpdatedAtDate toDeleteLocalRecords:(BOOL)toDelete {
    NSMutableArray *operations = [NSMutableArray array];
    
    for (NSString *className in self.registeredClassesToSync) {
        NSDate *mostRecentUpdatedDate = nil;
        if (useUpdatedAtDate) {
            mostRecentUpdatedDate = [self mostRecentUpdatedAtDateForEntityWithName:className];
        }
    //}
    //[request .GET]
    /*request(.GET, "http://aditplanet.com/api/v1/deals/all", parameters: ["foo": "bar"])
    .responseSwiftyJSON { (request, response, json, error) in
        println(json["data"][0]["terms"])
        println(error)
        //   var item = json["0"] as NSDictionary
        //    println(item)
    }*/
    
    //[self processJSONDataRecordsIntoCoreData];

    
        NSMutableURLRequest *request = [[SDAFParseAPIClient sharedClient]
                                        GETRequestForAllRecordsOfClass:className
                                        updatedAfterDate:mostRecentUpdatedDate];
        AFHTTPRequestOperation *operation = [[SDAFParseAPIClient sharedClient] HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
            if ([responseObject isKindOfClass:[NSDictionary class]]) {
                [self writeJSONResponse:responseObject toDiskForClassWithName:className];
            }            
        } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
            NSLog(@"Request for class %@ failed with error: %@", className, error);
        }];
        
        [operations addObject:operation];
        
    }
    
    [[SDAFParseAPIClient sharedClient] enqueueBatchOfHTTPRequestOperations:operations progressBlock:^(NSUInteger numberOfCompletedOperations, NSUInteger totalNumberOfOperations) {
        
    } completionBlock:^(NSArray *operations) {

        if (!toDelete) {
            [self processJSONDataRecordsIntoCoreData];
        } else {
            [self processJSONDataRecordsForDeletion];
        }
    }];
    
    
}
- (NSManagedObjectContext*)managedObjectContext{
       return [[SDCoreDataController sharedInstance] backgroundManagedObjectContext];
}

- (void)processJSONDataRecordsIntoCoreData {
    NSManagedObjectContext *managedObjectContext = [[SDCoreDataController sharedInstance] backgroundManagedObjectContext];
    //    AppDelegate *appDel = [[UIApplication sharedApplication] delegate];
    //    NSManagedObjectContext *context = [appDel managedObjectContext];

    //NSManagedObjectContext * managedObjectContext = [appDel managedObjectContext];
    for (NSString *className in self.registeredClassesToSync) {
        int currentIndex = 0;
        //force to sync each time
        
        if (![self initialSyncComplete]) { // import all downloaded data to Core Data for initial sync
//            if (true) { // import all downloaded data to Core Data for initial sync
            NSDictionary *JSONDictionary = [self JSONDictionaryForClassWithName:className];
            NSArray *records = [JSONDictionary objectForKey:@"data"];
            for (NSDictionary *record in records) {
                [self newManagedObjectWithClassName:className forRecord:record];
            }
        } else {
            NSArray *downloadedRecords = [self JSONDataRecordsForClass:className sortedByKey:@"id"];
            if ([downloadedRecords lastObject]) {
                NSArray *storedRecords = [self managedObjectsForClass:className sortedByKey:@"id" usingArrayOfIds:[downloadedRecords valueForKey:@"id"] inArrayOfIds:YES];
                for (NSDictionary *record in downloadedRecords) {
                    NSManagedObject *storedManagedObject = nil;
                    if ([storedRecords count] > currentIndex) {
                        storedManagedObject = [storedRecords objectAtIndex:currentIndex];
                    }
                    
                    if ([[storedManagedObject valueForKey:@"id"] isEqualToString:[record valueForKey:@"id"]]) {
                        [self updateManagedObject:[storedRecords objectAtIndex:currentIndex] withRecord:record];
                    } else {
                        [self newManagedObjectWithClassName:className forRecord:record];
                    }
                    currentIndex++;
                }
            }
        }
        NSError *error = nil;
        if (![managedObjectContext save:&error]) {
            NSLog(@"Unable to save context for class %@", className);
        }else{
            NSLog(@"saved context for class %@--%d", className,currentIndex);
        }
        
        /*
        [managedObjectContext performBlockAndWait:^{
            NSError *error = nil;
            if (![managedObjectContext save:&error]) {
                NSLog(@"Unable to save context for class %@", className);
            }else{
                NSLog(@"saved context for class %@", className);
            }
        }];
        */
        
        //CoreDataBase cdb = [[CoreDataBase alloc] init];
        //cdb
        [self deleteJSONDataRecordsForClassWithName:className];
    }

    //var results = [context executeFetchRequest(cdrequest, error: &error);
    //println(error)
    //NSLog(results);

    //[self downloadDataForRegisteredObjects:NO toDeleteLocalRecords:YES];
//    AppDelegate *appDel = [[UIApplication sharedApplication] delegate];
//    NSManagedObjectContext *context = [appDel managedObjectContext];
    
    /*var newUser = NSEntityDescription.insertNewObjectForEntityForName("Users", inManagedObjectContext: context) as NSManagedObject
     
     newUser.setValue("Alex Song", forKey: "username")
     newUser.setValue("1234cc", forKey: "password")
     
     context.save(nil)
    NSFetchRequest* cdrequest = [NSFetchRequest fetchRequestWithEntityName:@"Holiday"]; // iOS 5 method
    cdrequest.returnsObjectsAsFaults = NO;
    NSError * error;
    NSArray *results = [managedObjectContext executeFetchRequest:cdrequest error:&error];
    
     */
     [self downloadDataForRegisteredObjects:NO toDeleteLocalRecords:YES];
}

- (void)processJSONDataRecordsForDeletion {
    NSManagedObjectContext *managedObjectContext = [[SDCoreDataController sharedInstance] backgroundManagedObjectContext];
    for (NSString *className in self.registeredClassesToSync) {
        NSArray *JSONRecords = [self JSONDataRecordsForClass:className sortedByKey:@"id"];
        if ([JSONRecords count] > 0) {
            NSArray *storedRecords = [self 
                                      managedObjectsForClass:className 
                                      sortedByKey:@"id"
                                      usingArrayOfIds:[JSONRecords valueForKey:@"id"]
                                      inArrayOfIds:NO];
            
            [managedObjectContext performBlockAndWait:^{
                for (NSManagedObject *managedObject in storedRecords) {
                    [managedObjectContext deleteObject:managedObject];
                }
                NSError *error = nil;
                BOOL saved = [managedObjectContext save:&error];
                if (!saved) {
                    NSLog(@"Unable to save context after deleting records for class %@ because %@", className, error);
                }
            }];
        }
        
        [self deleteJSONDataRecordsForClassWithName:className];
    }
    
    [self postLocalObjectsToServer];
}

- (void)newManagedObjectWithClassName:(NSString *)className forRecord:(NSDictionary *)record {
    NSManagedObject *newManagedObject = [NSEntityDescription insertNewObjectForEntityForName:className inManagedObjectContext:[[SDCoreDataController sharedInstance] backgroundManagedObjectContext]];
    
    [record enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *strKey = (NSString *)key;
        /*
        if ([strKey isEqualToString:@"images"]) {
                    [self setValue:@"foo" forKey:@"images" forManagedObject:newManagedObject];
        }*/
         /*else if([strKey isEqualToString:@"adpoints"]){
             [self setValue:obj forKey:strKey forManagedObject:newManagedObject];
        }
        
        else if([strKey isEqualToString:@"subtitle"])
        {
/*            NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
            [dateFormatter setDateFormat:@"hhmm"];
            NSString *CurrentTime = [dateFormatter stringFromDate:[NSDate date]];
            NSString *SessionID = [NSString stringWithFormat:@"Username %@", CurrentTime];

            [self setValue:[NSString stringWithFormat:@"%@-%s", CurrentTime,obj] forKey:strKey forManagedObject:newManagedObject];
        }*/
        //else{
            [self setValue:obj forKey:strKey forManagedObject:newManagedObject];
        //}

    }];
    
    [record setValue:[NSNumber numberWithInt:SDObjectSynced] forKey:@"syncStatus"];
}

- (void)updateManagedObject:(NSManagedObject *)managedObject withRecord:(NSDictionary *)record {
    [record enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [self setValue:obj forKey:key forManagedObject:managedObject];
    }];
}

- (void)setValue:(id)value forKey:(NSString *)key forManagedObject:(NSManagedObject *)managedObject {
    if ([key isEqualToString:@"createdAt"]
        || [key isEqualToString:@"updatedAt"]
        || [key isEqualToString:@"end_date"]
        || [key isEqualToString:@"hot_end"]
        || [key isEqualToString:@"hot_start"]
        || [key isEqualToString:@"start_date"]
        || [key isEqualToString:@"valit_end"]
        || [key isEqualToString:@"valit_start"]
        || [key isEqualToString:@"featured_end_date"]
        || [key isEqualToString:@"updatedAt"]) {
        //NSDate *date = [NSDate date];
        NSDate *date = [self dateUsingStringFromAPI:value];
        [managedObject setValue:date forKey:key];
    } else if([key isEqualToString:@"images"]) {
        //NSDate *date = [NSDate date];
        //NSDate *date = [self dateUsingStringFromAPI:value];
        //double num = [value doubleValue];
        //[managedObject setValue:[NSNumber numberWithDouble:num] forKey:key];
        NSString *image_string = [[value valueForKey:@"description"] componentsJoinedByString:@","];
        [managedObject setValue:image_string forKey:key];

    }  else if ([key isEqualToString:@"adpoints"]) {
        //NSDate *date = [NSDate date];
        //NSDate *date = [self dateUsingStringFromAPI:value];
        double num = [value doubleValue];
        [managedObject setValue:[NSNumber numberWithDouble:num] forKey:key];
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        if ([value objectForKey:@"__type"]) {
            NSString *dataType = [value objectForKey:@"__type"];
            if ([dataType isEqualToString:@"Date"]) {
                NSString *dateString = [value objectForKey:@"iso"];
                NSDate *date = [self dateUsingStringFromAPI:dateString];
                [managedObject setValue:date forKey:key];
            } else if ([dataType isEqualToString:@"File"]) {
                NSString *urlString = [value objectForKey:@"url"];
                NSURL *url = [NSURL URLWithString:urlString];
                NSURLRequest *request = [NSURLRequest requestWithURL:url];
                NSURLResponse *response = nil;
                NSError *error = nil;
                NSData *dataResponse = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
                [managedObject setValue:dataResponse forKey:key];
            } else {
                NSLog(@"Unknown Data Type Received");
                [managedObject setValue:nil forKey:key];
            }
        }
    } else {
        [managedObject setValue:value forKey:key];
    }
}

- (void)postLocalObjectsToServer {
    NSMutableArray *operations = [NSMutableArray array];    
    for (NSString *className in self.registeredClassesToSync) {
        NSArray *objectsToCreate = [self managedObjectsForClass:className withSyncStatus:SDObjectCreated];
        for (NSManagedObject *objectToCreate in objectsToCreate) {
            NSDictionary *jsonString = [objectToCreate JSONToCreateObjectOnServer];
            NSMutableURLRequest *request = [[SDAFParseAPIClient sharedClientForClass:className] POSTRequestForClass:className parameters:jsonString];
            
            AFHTTPRequestOperation *operation = [[SDAFParseAPIClient sharedClientForClass:className] HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                NSLog(@"Success creation: %@", responseObject);
                NSDictionary *responseDictionary = responseObject;
                NSDate *createdDate = [self dateUsingStringFromAPI:[responseDictionary valueForKey:@"createdAt"]];
                [objectToCreate setValue:createdDate forKey:@"createdAt"];
                [objectToCreate setValue:[responseDictionary valueForKey:@"objectId"] forKey:@"objectId"];
                [objectToCreate setValue:[NSNumber numberWithInt:SDObjectSynced] forKey:@"syncStatus"];
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Failed creation: %@", error);
            }];
            [operations addObject:operation];
        }
    }
    
    [[SDAFParseAPIClient sharedClient] enqueueBatchOfHTTPRequestOperations:operations progressBlock:^(NSUInteger numberOfCompletedOperations, NSUInteger totalNumberOfOperations) {
        NSLog(@"Completed %d of %d create operations", numberOfCompletedOperations, totalNumberOfOperations);
    } completionBlock:^(NSArray *operations) { 
        if ([operations count] > 0) {
            NSLog(@"Creation of objects on server compelete, updated objects in context: %@", [[[SDCoreDataController sharedInstance] backgroundManagedObjectContext] updatedObjects]);
            [[SDCoreDataController sharedInstance] saveBackgroundContext];
            NSLog(@"SBC After call creation");
        }

        [self deleteObjectsOnServer];
        
    }];
}

- (void)deleteObjectsOnServer {
    NSMutableArray *operations = [NSMutableArray array];    
    for (NSString *className in self.registeredClassesToSync) {
        NSArray *objectsToDelete = [self managedObjectsForClass:className withSyncStatus:SDObjectDeleted];
        for (NSManagedObject *objectToDelete in objectsToDelete) {
            NSMutableURLRequest *request = [[SDAFParseAPIClient sharedClientForClass:className]
                                            DELETERequestForClass:className 
                                            forObjectWithId:[objectToDelete valueForKey:@"objectId"]];
            
            AFHTTPRequestOperation *operation = [[SDAFParseAPIClient sharedClientForClass:className] HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                NSLog(@"Success deletion: %@", responseObject);
                [[[SDCoreDataController sharedInstance] backgroundManagedObjectContext] deleteObject:objectToDelete];
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Failed to delete: %@", error);
            }];
            
            [operations addObject:operation];
        }
    }
    
    [[SDAFParseAPIClient sharedClient] enqueueBatchOfHTTPRequestOperations:operations progressBlock:^(NSUInteger numberOfCompletedOperations, NSUInteger totalNumberOfOperations) {
        
    } completionBlock:^(NSArray *operations) {
        if ([operations count] > 0) {
            NSLog(@"Deletion of objects on server compelete, updated objects in context: %@", [[[SDCoreDataController sharedInstance] backgroundManagedObjectContext] updatedObjects]);
        }
        
        [self executeSyncCompletedOperations];
    }];
}

- (NSArray *)managedObjectsForClass:(NSString *)className withSyncStatus:(SDObjectSyncStatus)syncStatus {
    __block NSArray *results = nil;
    NSManagedObjectContext *managedObjectContext = [[SDCoreDataController sharedInstance] backgroundManagedObjectContext];
    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:className];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"syncStatus = %d", syncStatus];
    [fetchRequest setPredicate:predicate];
    [managedObjectContext performBlockAndWait:^{
        NSError *error = nil;
        results = [managedObjectContext executeFetchRequest:fetchRequest error:&error];
    }];
    
    return results;    
}

- (NSArray *)managedObjectsForClass:(NSString *)className sortedByKey:(NSString *)key usingArrayOfIds:(NSArray *)idArray inArrayOfIds:(BOOL)inIds {
    __block NSArray *results = nil;
    NSManagedObjectContext *managedObjectContext = [[SDCoreDataController sharedInstance] backgroundManagedObjectContext];
    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:className];
    NSPredicate *predicate;
    if (inIds) {
        predicate = [NSPredicate predicateWithFormat:@"id IN %@", idArray];
    } else {
        predicate = [NSPredicate predicateWithFormat:@"NOT (id IN %@)", idArray];
    }
    
    [fetchRequest setPredicate:predicate];
    [fetchRequest setSortDescriptors:[NSArray arrayWithObject:
                                      [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES]]];
    [managedObjectContext performBlockAndWait:^{
        NSError *error = nil;
        results = [managedObjectContext executeFetchRequest:fetchRequest error:&error];
    }];
    
    return results;
}

- (void)initializeDateFormatter {
    if (!self.dateFormatter) {
        self.dateFormatter = [[NSDateFormatter alloc] init];
        [self.dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
        [self.dateFormatter setTimeZone:[NSTimeZone timeZoneWithName:@"GMT"]];
    }
}

- (NSDate *)dateUsingStringFromAPI:(NSString *)dateString {
    [self initializeDateFormatter];
    // NSDateFormatter does not like ISO 8601 so strip the milliseconds and timezone
    dateString = [dateString substringWithRange:NSMakeRange(0, [dateString length]-5)];
    
    return [self.dateFormatter dateFromString:dateString];
}

- (NSString *)dateStringForAPIUsingDate:(NSDate *)date {
    [self initializeDateFormatter];
    NSString *dateString = [self.dateFormatter stringFromDate:date];
    // remove Z
    dateString = [dateString substringWithRange:NSMakeRange(0, [dateString length]-1)];
    // add milliseconds and put Z back on
    dateString = [dateString stringByAppendingFormat:@".000Z"];
    
    return dateString;
}

#pragma mark - File Management

- (NSURL *)applicationCacheDirectory
{
    return [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject];
}

- (NSURL *)JSONDataRecordsDirectory{
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *url = [NSURL URLWithString:@"JSONRecords/" relativeToURL:[self applicationCacheDirectory]];
    NSError *error = nil;
    if (![fileManager fileExistsAtPath:[url path]]) {
        [fileManager createDirectoryAtPath:[url path] withIntermediateDirectories:YES attributes:nil error:&error];
    }
    
    return url;
}

- (void)writeJSONResponse:(id)response toDiskForClassWithName:(NSString *)className {
    NSURL *fileURL = [NSURL URLWithString:className relativeToURL:[self JSONDataRecordsDirectory]];
    if (![(NSDictionary *)response writeToFile:[fileURL path] atomically:YES]) {
        NSLog(@"Error saving response to disk, will attempt to remove NSNull values and try again.");
        // remove NSNulls and try again...
        NSArray *records = [response objectForKey:@"data"];
        NSMutableArray *nullFreeRecords = [NSMutableArray array];
        for (NSDictionary *record in records) {
            NSMutableDictionary *nullFreeRecord = [NSMutableDictionary dictionaryWithDictionary:record];
            [record enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                if ([obj isKindOfClass:[NSNull class]]) {
                    [nullFreeRecord setValue:nil forKey:key];
                }
            }];
            [nullFreeRecords addObject:nullFreeRecord];
        }
        
        NSDictionary *nullFreeDictionary = [NSDictionary dictionaryWithObject:nullFreeRecords forKey:@"data"];
        
        if (![nullFreeDictionary writeToFile:[fileURL path] atomically:YES]) {
            NSLog(@"Failed all attempts to save reponse to disk: %@", response);
        }
    }
}

- (void)deleteJSONDataRecordsForClassWithName:(NSString *)className {
    NSURL *url = [NSURL URLWithString:className relativeToURL:[self JSONDataRecordsDirectory]];
    NSError *error = nil;
    BOOL deleted = [[NSFileManager defaultManager] removeItemAtURL:url error:&error];
    if (!deleted) {
        //NSLog(@"Unable to delete JSON Records at %@, reason: %@", url, error);
    }
}

- (NSDictionary *)JSONDictionaryForClassWithName:(NSString *)className {
    NSURL *fileURL = [NSURL URLWithString:className relativeToURL:[self JSONDataRecordsDirectory]]; 
    return [NSDictionary dictionaryWithContentsOfURL:fileURL];
}

- (NSArray *)JSONDataRecordsForClass:(NSString *)className sortedByKey:(NSString *)key {
    NSDictionary *JSONDictionary = [self JSONDictionaryForClassWithName:className];
    NSArray *records = [JSONDictionary objectForKey:@"data"];
    return [records sortedArrayUsingDescriptors:[NSArray arrayWithObject:
                                                 [NSSortDescriptor sortDescriptorWithKey:key ascending:YES]]];
}
@end
