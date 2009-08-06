//
//  LGSmartScanner.m
//  Vertex Watcher
//
//  Created by Louis Gerbarg on 8/6/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#include <mach/mach_error.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <IOKit/storage/IOStorageDeviceCharacteristics.h>

#import "LGSmartScanner.h"

#define kWindowSMARTVertexAvgWriteCount						0xD0
#define kWindowSMARTVerteAvailableLife						0xD1

// This constant comes from the SMART specification.  Only 30 values are allowed in any of the structures.
#define kSMARTAttributeCount	30


typedef struct IOATASmartAttribute
{
    UInt8 			attributeId;
    UInt16			flag;  
    UInt8 			current;
    UInt8 			worst;
    UInt8 			rawvalue[6];
    UInt8 			reserv;
}  __attribute__ ((packed)) IOATASmartAttribute;

typedef struct IOATASmartVendorSpecificData
{
    UInt16 					revisonNumber;
    IOATASmartAttribute		vendorAttributes [kSMARTAttributeCount];
} __attribute__ ((packed)) IOATASmartVendorSpecificData;

@interface LGSmartScanner (Private)
-(void) scanSmartDataForInterface:(io_service_t) smartInterface;
@end

@implementation LGSmartScanner

@synthesize wearCount;
@synthesize lifePercent;
@synthesize drive;

- (id) init {
  self = [super init];
  
  if (self) {
    [NSTimer scheduledTimerWithTimeInterval:0.0 target:self selector:@selector(scan) userInfo:nil repeats:NO];
    [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(scan) userInfo:nil repeats:YES];
  }
  
  return self;
}

- (void) finalize {
  if (self.drive != IO_OBJECT_NULL) {
    IOObjectRelease(self.drive);
  }
  
  [super finalize];
}

- (void) scan {
  if (self.drive == IO_OBJECT_NULL) {
    io_iterator_t			iter			= IO_OBJECT_NULL;
    io_object_t obj = IO_OBJECT_NULL;
    NSDictionary *subDict = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@kIOPropertySMARTCapableKey];
    NSDictionary *matchingDict = [NSDictionary dictionaryWithObject:subDict forKey:@ kIOPropertyMatchKey];
    IOReturn error = IOServiceGetMatchingServices (kIOMasterPortDefault, (CFDictionaryRef)matchingDict, &iter);
    
    if (error != kIOReturnSuccess) {
      printf("Error finding SMART Capable disks: %s(%x)\n", mach_error_string(error), error);
    } else {
      while ((obj = IOIteratorNext(iter)) != IO_OBJECT_NULL) {		
        
        NSDictionary *dict = NSMakeCollectable(IORegistryEntryCreateCFProperty(obj, CFSTR(kIOPropertyDeviceCharacteristicsKey), kCFAllocatorDefault, 0));
        NSString *productNameString = [[dict objectForKey:@kIOPropertyProductNameKey] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *versionString = [[dict objectForKey:@kIOPropertyProductRevisionLevelKey] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSArray *versionValues = [versionString componentsSeparatedByString:@"."];
        NSInteger majorVersion = [[versionValues objectAtIndex:0] integerValue];
        NSInteger minorVersion = [[versionValues objectAtIndex:1] integerValue];

        
        NSLog(@"%@/%u.%u", productNameString, majorVersion,minorVersion);
        
        if (majorVersion == 1 && minorVersion >= 3 && [productNameString isEqual:@"OCZ-VERTEX"]) {
         //We found a compatible device
          self.drive = obj;
          IOObjectRetain(self.drive);          
        }
        
        IOObjectRelease(obj);
      }
    }
    IOObjectRelease(iter);
  }
  
	[self scanSmartDataForInterface:self.drive];
}

-(void) scanSmartDataForInterface:(io_service_t) service {
	IOCFPlugInInterface **		cfPlugInInterface	= NULL;
	IOATASMARTInterface **		smartInterface		= NULL;
	SInt32						score				= 0;
	HRESULT						herr				= S_OK;
	IOReturn					err					= kIOReturnSuccess;

	require_string((service != IO_OBJECT_NULL), ErrorExit1, "unable to obtain service using [self GetDeviceObject]");
	
	err = IOCreatePlugInInterfaceForService (service,
												kIOATASMARTUserClientTypeID,
												kIOCFPlugInInterfaceID,
												&cfPlugInInterface,
												&score );
	
	require_string ( ( err == kIOReturnSuccess ), ErrorExit1,
					 "IOCreatePlugInInterfaceForService failed" );
	
	herr = ( *cfPlugInInterface )->QueryInterface (
										cfPlugInInterface,
										CFUUIDGetUUIDBytes ( kIOATASMARTInterfaceID ),
										( LPVOID ) &smartInterface );
	
	require_string ( ( herr == S_OK ), ErrorExit2,
					 "QueryInterface failed" );
  
  
	IOReturn									error				= kIOReturnSuccess;
	ATASMARTData								smartData;
	IOATASmartVendorSpecificData				smartDataVendorSpecifics;

	bzero(&smartData, sizeof(smartData));
	bzero(&smartDataVendorSpecifics, sizeof(smartDataVendorSpecifics));


	// Start by enabling S.M.A.R.T. reporting for this disk.
	error = (*smartInterface)->SMARTEnableDisableOperations(smartInterface, true);
	require_string((error == kIOReturnSuccess), ErrorExit3, "SMARTEnableDisableOperations failed");
	
	error = (*smartInterface)->SMARTEnableDisableAutosave(smartInterface, true);
	require_string((error == kIOReturnSuccess), ErrorExit3, "SMARTEnableDisableAutosave failed");



	// NOTE:
	// The rest of the diagnostics gathering involves using portions of the API that is considered
	// optional for a drive vendor to implement.  Most vendors now do, but be warned not to rely
	// on it.  In particular, the attribute codes are usually considered vendor specific and
	// proprietary, although some codes (ie. drive temperature) are almost always present.


	// Ask the device to start collecting S.M.A.R.T. data immediately.  We are not asking
	// for an extended test to be performed at this point
	error = (*smartInterface)->SMARTExecuteOffLineImmediate (smartInterface, false);
	if (error != kIOReturnSuccess)
		printf("SMARTExecuteOffLineImmediate failed: %s(%x)\n", mach_error_string(error), error);


	// Next, a demonstration of how to extract the raw S.M.A.R.T. data attributes.
	// A drive can report up to 30 of these, but all are optional.  Normal values
	// vary by vendor, although the property used for this demonstration always
	// reports in degrees celcius
	error = (*smartInterface)->SMARTReadData(smartInterface, &smartData);
	if (error != kIOReturnSuccess) {
		printf("SMARTReadData failed: %s(%x)\n", mach_error_string(error), error);
	} else {
		error = (*smartInterface)->SMARTValidateReadData(smartInterface, &smartData);
		if (error != kIOReturnSuccess) {
			printf("SMARTValidateReadData failed for attributes: %s(%x)\n", mach_error_string(error), error);
		} else {
			smartDataVendorSpecifics = *((IOATASmartVendorSpecificData *)&(smartData.vendorSpecific1));

			int currentAttributeIndex = 0;
			for (currentAttributeIndex = 0; currentAttributeIndex < kSMARTAttributeCount; currentAttributeIndex++) {
				IOATASmartAttribute currentAttribute = smartDataVendorSpecifics.vendorAttributes[currentAttributeIndex];

				if (currentAttribute.attributeId == kWindowSMARTVertexAvgWriteCount) {
          self.wearCount = [NSNumber numberWithUnsignedChar:currentAttribute.current];
				}
        
        if (currentAttribute.attributeId == kWindowSMARTVerteAvailableLife) {
        	self.lifePercent = [NSNumber numberWithUnsignedChar:currentAttribute.current];
				}
			}
		}
	}	

//State unwinds for error conditions

ErrorExit3:
	// Now that we're done, shut down the S.M.A.R.T.  If we don't, storage takes a big performance hit.
	// We should be able to ignore any error conditions here safely
	error = (*smartInterface)->SMARTEnableDisableAutosave(smartInterface, false);
	error = (*smartInterface)->SMARTEnableDisableOperations(smartInterface, false);
  ( *smartInterface )->Release ( smartInterface );
	smartInterface = NULL;
  
ErrorExit2:
	IODestroyPlugInInterface ( cfPlugInInterface );
	cfPlugInInterface = NULL;

ErrorExit1:
  return;
}


@end
