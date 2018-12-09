function Get-ProductKey {
     <#   
    .SYNOPSIS   
        Retrieves product keys and OS information from a local or remote system/s.
         
    .DESCRIPTION   
        Retrieves the product key and OS information from a local or remote system/s using WMI and/or ProduKey. Attempts to
		decode the product key from the registry, shows product keys from SoftwareLicensingProduct (SLP), and attempts to use
		ProduKey as well. Enables RemoteRegistry service if required.
		Originally based on this script: https://gallery.technet.microsoft.com/scriptcenter/Get-product-keys-of-local-83b4ce97
		
		Note that giving credentials with ProduKey requires running the process locally with those credentials, so they must
		work on the local machine.
        
		NOTE: Requires Powershell v2.0 or higher.
		
	.PARAMETER Computername
        Strings. Name of the local or remote system/s.
	
	.PARAMETER ShowOnlyValid
        Switch. Output only fully valid entries (pingable, has WMI access).
	
	.PARAMETER DontEnableRemoteRegistry
		Switch. Do NOT attempt to enable the RemoteRegistry service if it's disabled.
	
	.PARAMETER SkipRegProductKey
		Switch. Skip attempting to decode the product key from the registry (non-VLK/MAK only, requires RemoteRegistry if remote).
		
	.PARAMETER SkipOEMInfo
		Switch. Skip outputting OEM info from WMI / registry.
		
	.PARAMETER SkipProduKey
        Switch. Skip attempting to use ProduKey for additional keys (requires RemoteRegistry access for remote machines).
		
	.PARAMETER ProduKeyPath
		String. Path to ProduKey.exe and its working directory. Default: ".\" (current directory)
    
	.PARAMETER PromptForCredentials
		Switch. Prompt for secure credentials to use.
		
	.PARAMETER Credential
		Secure credential object to use instead of the current user's credentials.
		
    .NOTES   
        Author: Matthew Carras
		Version: 1.21
			- Fixed Powershell compatibility lower than v3.0.
		Version: 1.2
			- Fixed some of the logic for ProduKey, changing the "ProduKeyPath" parameter in the process.
		Version: 1.1
			- Recoded getting product key from registry, including a working decoding function this time.
		Version: 1.0
			- Initial release
     
    .EXAMPLE 
     Get-ProductKey -Computername Computer1
    
	 OSDescription    : Microsoft Windows 10 Pro
	 Source           : SLP/WMI
	 ProductKey       : XXXXX
	 Hostname         : Computer1
	 OEMManufacturer  : Dell, Inc.
	 OSVersion        : 10.0.17134
	 ProductID        : NNNNN-NNNNN-NNN-NNNNNN-NN-NNNN-NNNNN.NNNN-NNNNNNN
	 IP               : 192.168.1.2
	 OEMModel         : Optiplex 320
	 SLPLicenseStatus : Licensed
	 ProductName      : Windows(R), Professional edition

	 OSDescription    : Microsoft Windows 10 Pro
	 Source           : HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\DigitalProductId
	 ProductKey       : XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
	 Hostname         : Computer1
	 OEMManufacturer  : Dell, Inc.
	 OSVersion        : 10.0.17134
	 ProductID        : NNNNN-NNNNN-NNNNN-NNNNN
	 IP               : 192.168.1.2
	 OEMModel         : Optiplex 320
	 SLPLicenseStatus :
	 ProductName      : Windows 10 Pro
	 
	 OSDescription    : Microsoft Windows 10 Pro
	 Source           : ProduKey
	 ProductKey       : XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
	 Hostname         : Computer1
	 OEMManufacturer  : Dell, Inc.
	 OSVersion        : 10.0.17134
	 ProductID        : NNNNN-NNNNN-NNNNN-NNNNN
	 IP               : 192.168.1.2
	 OEMModel         : Optiplex 320
	 SLPLicenseStatus :
	 ProductName      : Windows 10 Pro
    #>         
    [CmdletBinding(DefaultParameterSetName = 'Local')]
    Param (
	    # Remote computer name to query
		[Parameter(ParameterSetName = 'Remote')]
		[Parameter(Mandatory = $false,ValueFromPipeLine=$True,ValueFromPipeLineByPropertyName=$True)]
		[Alias("CN","__Server","IPAddress","Server")]
        [string[]] $ComputerName,
		
		# Output only fully valid entries (reachable, has WMI access).
		[Parameter(Mandatory = $false)]
		[Switch] $ShowOnlyValid,
		
		# Attempt to remotely enable the RemoteRegistry service if it's stopped. Required for all except SLP partial keys
		[Parameter(Mandatory = $false)]
		[Switch] $DontEnableRemoteRegistry,
		
		# Skip attempting to get and decode the Product Key from the registry
		[Parameter(Mandatory = $false)]
		[Switch] $SkipRegProductKey,
		
		# Skip attempting to get OEM Info from the registry (also removes it from columns)
		[Parameter(Mandatory = $false)]
		[Switch] $SkipOEMInfo,
		
		# Skip attempting to use ProduKey.exe on remote computer, if it exists, parsing the results
		[Parameter(Mandatory = $false)]
		[Switch] $SkipProduKey,
		
		# Location of ProduKey.exe
		[Parameter(Mandatory = $false)]
		[string] $ProduKeyPath = '.\',
		
		# Prompt for credentials using Get-Credential
		[Parameter(Mandatory = $false)]
		[Switch] $PromptForCredentials,
		
		# Credential to use for all local and remote queries, if given
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential] $Credential
    ) #end param
    Begin {   
		$TempDir = [System.IO.Path]::GetTempPath(); # Get %TEMP%
		$ProduKeyExe = "ProduKey.exe"
		$ProduKeyCSVFile = "$($TempDir)result-produkey.csv"
		$ProduKeyCSVHeader="ProductName","ProductID","ProductKey","InstallFolder","ServicePack","BuildNumber","ComputerName","ModifiedTime"
		[uint32]$HKLM = 2147483650 # HKEY_LOCAL_MACHINE definition for GetStringValue($hklm, $subkey, $value)
		
		# Delimiter for converting to string (in case it's needed)
		$ofs = '; '
		
		# IP address of local machine, used to determine whether a given hostname is the local machine
		Try {
			$sLocalIP = [string]([System.Net.Dns]::GetHostAddresses($Env:ComputerName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -Expand IPAddressToString)
		} Catch {
			$sLocalIP = '127.0.0.1'
		}
		
		# Define local function to decode binary product key data in registry
		# VBS Source: https://forums.mydigitallife.net/threads/vbs-windows-oem-slp-key.25284/
		function DecodeProductKeyData{
			param( 
				[Parameter(Mandatory = $true)]
				[byte[]]$BinaryValuePID 
			)
			Begin {
				# for decoding product key
				$KeyOffset = 52
				$CHARS="BCDFGHJKMPQRTVWXY2346789" # valid characters in product key
				$insert = 'N' # for Win8 or 10+
			} #end Begin
			Process {
				$ProductKey = ''
				$isWin8_or_10 = [math]::floor($BinaryValuePID[66] / 6) -band 1
				$BinaryValuePID[66] = ($BinaryValuePID[66] -band 0xF7) -bor (($isWin8_or_10 -band 2) * 4)
				for ( $i = 24; $i -ge 0; $i-- ) {
					$Cur = 0
					for ( $X = $KeyOffset+14; $X -ge $KeyOffset; $X-- ) {
						$Cur = $Cur * 256
						$Cur = $BinaryValuePID[$X] + $Cur
						$BinaryValuePID[$X] = [math]::Floor([double]($Cur/24))
						$Cur = $Cur % 24
					} #end for $X
					$ProductKey = $CHARS[$Cur] + $ProductKey
				} #end for $i
				If ( $isWin8_or_10 -eq 1 ) {
					$ProductKey = $ProductKey.Insert($Cur+1, $insert)
				}
				$ProductKey = $ProductKey.Substring(1)
				for ($i = 5; $i -le 26; $i += 6) {
					$ProductKey = $ProductKey.Insert($i, '-')
				}
				$ProductKey
			} #end Process
		} # end DecodeProductKeyData function
    } # end Begin
    Process {
		$WmiSplat = @{ ErrorAction = 'Stop' } # Given to all WMI-related commands
		
		If ( $PromptForCredentials ) {
			$Credential = Get-Credential -Message "Credentials for Get-ProductKey"
		}
		If ( $Credential ) {
			Write-Verbose ("Using given credentials for user [{0}]" -f $Credential.Username)
			$WmiSplat.Add('Credential', $Credential)
		}
		
		# Add local machine to list of Computers if none is given
		$bRemoteParamSet = [bool]( $PSCmdlet.ParameterSetName -eq 'Remote' )
		If ( -Not $bRemoteParamSet ) {
			$ComputerName = [string[]]$Env:ComputerName
			Write-Verbose ("Running against only localhost")
		}
		
		$ProduKeyFullPath = "{0}{1}" -f $ProduKeyPath,$ProduKeyExe
		
		$aKeys = @() # collect all the objects into one array to output at the end
        ForEach ($Computer in $ComputerName) {
			$Hostname = $Computer
			$IP = $Computer
			$OEMManufacturer = ''
			$OEMModel = ''
			$bDoRemote = $bRemoteParamSet # we are accessing a remote computer
						
			If ( $bDoRemote ) { 
				Write-Verbose ("{0}: Checking network availability" -f $Computer)
			}
            If (-Not $bDoRemote -Or ( Test-Connection -ComputerName $Computer -Count 1 -Quiet) ) {
				# Get hostname
				$bHostnameOK = $true
				Try {
					$Hostname = [string]([System.Net.Dns]::GetHostByAddress($Computer).Hostname)
				} Catch {
					$bHostnameOK = $false # Try using WMI later
				}
				# Get IP address
				Try {
					$IP = [string]([System.Net.Dns]::GetHostAddresses($Computer) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -Expand IPAddressToString)
				} Catch {
					# do nothing
				} # end try/catch

				# Check to see if this is the local machine
				If ( $IP -eq $sLocalIP -Or $Hostname.ToLower() -eq ($Env:ComputerName).ToLower() ) {
					$bDoRemote = $false
					Write-Verbose ("{0}: Determined this is localhost" -f $Computer)
				}
				
				# Get WMI info for both OS and SLP
				$bWMIOK = $true
                Try {
                    Write-Verbose ("{0}: Retrieving WMI OS information" -f $Computer)
					# Get OS and Computer info
                    $OS = Get-WmiObject -ComputerName $Computer Win32_OperatingSystem @WmiSplat 
					$CS = Get-WmiObject -ComputerName $Computer Win32_ComputerSystem @WmiSplat
					$OEMManufacturer = $CS.Manufacturer
					$OEMModel = $CS.Model
					
					# If we don't have a hostname, use the one from ComputerSystem
					if ( -Not $bHostnameOK ) {
						$Hostname = $CS.Name
					} #end if
					
					# Iterate through all instances of SLP
					 Write-Verbose ("{0}: Retrieving WMI SoftwareLicensingProduct (SLP) information" -f $Computer)
					$SLP = Get-WmiObject -ComputerName $Computer SoftwareLicensingProduct @WmiSplat | where {$_.PartialProductKey}
					foreach ($result in $SLP) {
						# 1 = Activated, 0 = Unactivated, etc.
						switch ( $result.LicenseStatus ) {
							0 { $LicenseStatus = "UNLICENSED" }	
							1 { $LicenseStatus = "Licensed" }
							2 { $LicenseStatus = "OOB Grace Period" }
							3 { $LicenseStatus = "Out-Of-Tolerance Grace Period" }
							4 { $LicenseStatus = "Non-Genuine Grace Period" }
							5 { $LicenseStatus = "NOTIFICATION" }
							6 { $LicenseStatus = "Extended Grace" }
							default { $LicenseStatus = [string]$result.LicenseStatus }
						}
						# Collect SLP key
						$aKeys += New-Object PSObject -Property @{
							Hostname = $Hostname
							IP = $IP
							ProductID = $result.ProductKeyID
							ProductKey = [string]$result.PartialProductKey
							SLPLicenseStatus = $LicenseStatus
							ProductName = $result.Name
							OSVersion = $os.version
							OSDescription = $os.caption
							OEMManufacturer = $OEMManufacturer
							OEMModel = $OEMModel
							Source = "SLP/WMI"
						} # end object
					} #end foreach
					
					# Iterate through all instances of SLS (if applicable - mainly for Windows 8)
					# Note: SLS properties are different for older versions of Windows.
					Try {
						Write-Verbose ("{0}: Retrieving WMI SoftwareLicensingService (SLS) information" -f $Computer)
						$SLS = Get-WmiObject -ComputerName $Computer SoftwareLicensingService @WmiSplat | where {$_.OA3xOriginalProductKey}
						foreach ($result in $SLS) {
							# Collect SLS key
							$aKeys += New-Object PSObject -Property @{
								Hostname = $Hostname
								IP = $IP
								ProductID = ''
								ProductKey = [string]$result.OA3xOriginalProductKey
								SLPLicenseStatus = ''
								ProductName = [string]$result.OA3xOriginalProductKeyDescription
								OSVersion = $os.version
								OSDescription = $os.caption
								OEMManufacturer = $OEMManufacturer
								OEMModel = $OEMModel
								Source = "SLS/WMI"
							} # end object
						} #end foreach
					} Catch {
						Write-Verbose ("{0}: WARNING - could not retrieve WMI SoftwareLicensingService (SLS) information" -f $Computer)
					} # end try/catch
                } Catch {
					Write-Verbose ("{0}: WARNING - Could not query WMI" -f $Computer)
                    $OS = New-Object PSObject -Property @{
                        Caption = $_.Exception.Message
                        Version = $_.Exception.Message
						OSArchitecture = $_.Exception.Message
						SerialNumber = $_.Exception.Message
                    } # end object
					$CS = New-Object PSObject -Property @{
						Name = $Hostname
						Manufacturer = $_.Exception.Message
					} # end object
					$bWMIOK = $false
                } # end try/catch
				
				# Only continue if we have WMI access
				If ( $bWMIOK ) {
					# Query RemoteRegistry service and start it if needed
					$RevertServiceStatus = $false
					$PreviousServiceStatus = 'Stopped'
					If ( $bDoRemote ) {
						Write-Verbose ("{0}: Querying services for RemoteRegistry" -f $Computer)
						Try { 
							$service = Get-WmiObject -Namespace root\CIMV2 -Class Win32_Service -ComputerName $Computer -Filter "Name='RemoteRegistry' OR DisplayName='RemoteRegistry'" @WmiSplat
							$PreviousServiceStatus = [string]$service.State
							Write-Verbose ("{0}: RemoteRegistry is {1}" -f $Computer,$PreviousServiceStatus) 
							If ( -Not $DontEnableRemoteRegistry -And $PreviousServiceStatus -ne 'Running' ) {
								$result = $service.StartService()
								$RevertServiceStatus = $true
								Write-Verbose ("{0}: Enabled RemoteRegistry service" -f $Computer)
								Sleep 1
							} # end if
						} Catch {
							Write-Verbose ("{0}: WARNING - Could not get status of RemoteRegistry service" -f $Computer)
						}
					} # end if remote
					Try {
						if ( $bDoRemote ) {
							Write-Verbose ("{0}: Attempting remote registry access" -f $Computer)
						} Else {
							Write-Verbose ("{0}: Attempting local registry access" -f $Computer)
						}
						$remoteReg = Get-WmiObject -List -Namespace 'root\default' -ComputerName $Computer @WmiSplat | Where-Object {$_.Name -eq "StdRegProv"}
						# Get OEM info from registry
						If ( -Not $SkipOEMInfo ) {
							Write-Verbose ("{0}: Checking registry for OEM info" -f $Computer)
							$regManufacturer = ($remoteReg.GetStringValue($HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation','Manufacturer')).sValue
							$regModel = ($remoteReg.GetStringValue($HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation','Model')).sValue
							
							if ( $regManufacturer -And -Not $OEMManufacturer ) {
								$OEMManufacturer = $regManufacturer
							}
							if ( $regModel -And -Not $OEMModel ) {
								$OEMModel = $regModel
							}
						} # end if
						# Get & Decode Product Keys from registry
						If ( -Not $SkipRegProductKey ) {
							Write-Verbose ("{0}: Checking registry for product key" -f $Computer)						
							# Which one we query depends on OS Arch
							# If ($OS.OSArchitecture -eq '64-bit') {
								# $getvalue = 'DigitalProductId4'
							# } Else {
								# $getvalue = 'DigitalProductId'
							# }
							$getvalue = 'DigitalProductId'
							$regpaths = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion','SOFTWARE\Microsoft\Windows NT\CurrentVersion\DefaultProductKey','SOFTWARE\Microsoft\Windows NT\CurrentVersion\DefaultProductKey2'
							foreach ( $regpath in $regpaths ) {
								$fullpath = "HKLM\{0}\{1}" -f $regpath,$getvalue
								$key = ($remoteReg.GetBinaryValue($HKLM,$regpath,$getvalue)).uValue
								if ( $key ) {
									Write-Verbose ("{0}: Translating data into product key" -f $Computer)
									$ProductKey = DecodeProductKeyData $key

									$ProductName = ($remoteReg.GetStringValue($HKLM,$regpath,'ProductName')).sValue
									If ( -Not $ProductName ) { $ProductName = '' }
									
									$ProductID = ($remoteReg.GetStringValue($HKLM,$regpath,'ProductId')).sValue
									If ( -Not $ProductID ) { $ProductID = '' }
								
									# Collect product key from registry
									$aKeys += New-Object PSObject -Property @{
										Hostname = $Hostname
										IP = $IP
										ProductID = $ProductID
										ProductKey = $ProductKey
										SLPLicenseStatus = ''
										ProductName = $ProductName
										OSVersion = $os.version
										OSDescription = $os.caption
										OEMManufacturer = $OEMManufacturer
										OEMModel = $OEMModel
										Source = $fullpath
									} # end object
								} else {
									Write-Verbose ("{0}: WARNING - Product key not found under [{1}] in registry" -f $Computer,$fullpath)
									If ( -Not $ShowOnlyValid ) {
										$aKeys += New-Object PSObject -Property @{
											Hostname = $Hostname
											IP = $IP
											ProductID = ''
											ProductKey = 'Product Key not found'
											SLPLicenseStatus = ''
											ProductName = ''
											OSVersion = $os.version
											OSDescription = $os.caption
											OEMManufacturer = $OEMManufacturer
											OEMModel = $OEMModel
											Source = $fullpath
										} # end object
									} # end if
								} # end if we have a valid key
							} #end foreach
						} # end if we are checking the registry or not
						
						# Attempt to use ProduKey. Requires RemoteRegistry access
						If ( -Not $SkipProduKey ) {
							Write-Verbose ("{0}: Attempting to run ProduKey..." -f $Computer)
							If ( Test-Path $ProduKeyFullPath -PathType Leaf ) {
								# Remove any previous CSV results, as well as the configuration file.
								Remove-Item $ProduKeyCSVFile -ErrorAction SilentlyContinue
								Remove-Item "${$ProduKeyPath}ProduKey.cfg" -ErrorAction SilentlyContinue
								Try {
									# Run ProduKey, exporting to a CSV file. Use Start-Process with -Wait to avoid race condition. Use Credentials if given.
									# Note: Credentials must exist locally.
									If ( -Not $bDoRemote ) {
										Write-Verbose ("{0}: Running ProduKey locally only" -f $Computer)
										Start-Process -FilePath $ProduKeyFullPath -Args "/nosavereg","/scomma `"$ProduKeyCSVFile`"" -Wait -Verb Runas
									} ElseIf ( $Credential ) {
										Start-Process -FilePath $ProduKeyFullPath -Args "/remote $Computer","/nosavereg","/scomma `"$ProduKeyCSVFile`"" -NoNewWindow -Wait -Credential $Credential
									} Else {
										Start-Process -FilePath $ProduKeyFullPath -Args "/remote $Computer","/nosavereg","/scomma `"$ProduKeyCSVFile`"" -NoNewWindow -Wait
									}
									If ( Test-Path "$ProduKeyCSVFile" -PathType Leaf ) {
										Try {
											Write-Verbose ("{0}: Importing CSV results" -f $Computer)
											$results = Import-Csv -Header $ProduKeyCSVHeader "$ProduKeyCSVFile"
											$bComputernameWarning = $false # show warning only once
											# Parse CSV results
											foreach ( $result in $results ) {
												$ProductKey = [string]$result.ProductKey
												# Warn if ProduKey's computer name is different than hostname, just in case
												$ProduKeyComputername = $result.ComputerName
												If ( -Not $bComputernameWarning -And $ProduKeyComputername.ToLower() -ne $Hostname.ToLower() ) {
													Write-Verbose ("{0}: WARNING - Computer name from ProduKey [{1}] does not match hostname [{2}]" -f $Computer,$ProduKeyComputername,$Hostname)
													$bComputernameWarning = $true
												}
												If ( -Not $ShowOnlyValid -Or $ProductKey -notlike 'Product key was not found' ) {
													# Collect product key from ProduKey CSV results
													$aKeys += New-Object PSObject -Property @{
														Hostname = $Hostname
														IP = $IP
														ProductID = $result.ProductID
														ProductKey = $ProductKey
														SLPLicenseStatus = ''
														ProductName = $result.ProductName
														OSVersion = $os.version
														OSDescription = $os.caption
														OEMManufacturer = $OEMManufacturer
														OEMModel = $OEMModel
														Source = 'ProduKey'
													} # end object
												} # end if
											} #end foreach
										} Catch {
											Write-Verbose ("{0}: ERROR parsing CSV results from ProduKey" -f $Computer)
										} # end try/catch
									} Else {
										Write-Verbose ("{0}: ERROR - ProduKey did not seem to produce a CSV file" -f $Computer)
									} # end if valid CSV results file
								} Catch {
									Write-Verbose ("{0}: ERROR - Could not run [{1}]" -f $Computer,$ProduKeyFullPath)
								} # end try/catch
							} Else {
								Write-Verbose ("{0}: ERROR - [{1}] does not seem to exist" -f $Computer,$ProduKeyFullPath)
							} # end if valid path
						} # if we are attempting to use ProduKey
					} Catch {
						if ( $bDoRemote ) {
							Write-Verbose ("{0}: WARNING - No remote registry access." -f $Computer)
						} Else {
							Write-Verbose ("{0}: ERROR - Accessing the local registry failed." -f $Computer)
						}
					} # end try/catch
					# Set service status back to its original state
					If ( $RevertServiceStatus -And $bDoRemote ) {
						Try {
							$service = Get-WmiObject -Namespace root\CIMV2 -Class Win32_Service -ComputerName $Computer -Filter "Name='RemoteRegistry' OR DisplayName='RemoteRegistry'" @WmiSplat
							If ( $PreviousServiceStatus -eq 'Stopped' ) {
								$result = $service.StopService()
								Write-Verbose ("{0}: RemoteRegistry set back to {1}" -f $Computer,$PreviousServiceStatus)
							}
						} Catch {
							Write-Verbose ("{0}: WARNING - Could NOT restore RemoteRegistry back to {1} - {2}" -f $Computer,$PreviousServiceStatus,$_.Exception.Message)
						} # end try/catch
					} #end if we need to revert service status
				} ElseIf ( -Not $ShowOnlyValid ) {
					# WMI was NOT successful
					$aKeys += New-Object PSObject -Property @{
						Hostname = $Hostname
						IP = $IP
						ProductID = 'ERROR: No WMI access'
						ProductKey = 'ERROR: No WMI access'
						SLPLicenseStatus = 'ERROR: No WMI access'
						ProductName = 'ERROR: No WMI access'
						OSVersion = $os.version
						OSDescription = $os.caption
						OEMManufacturer = $cs.Manufacturer
						OEMModel = 'ERROR: No WMI access'
						Source = 'ERROR: No WMI access'
					} # end object
				} # if WMI is successful or not
            } ElseIf ( -Not $ShowOnlyValid ) {
				# Computer was unreachable
                $aKeys += New-Object PSObject -Property @{
                    Hostname = $Computer
					IP = $Computer
                    ProductID = 'Unreachable'
					ProductKey = 'Unreachable'
					SLPLicenseStatus = 'Unreachable'
					ProductName = 'Unreachable'
					OSVersion = 'Unreachable'
					OSDescription = 'Unreachable'
					OEMManufacturer = 'Unreachable'
					OEMModel = 'Unreachable'
					Source = 'Unreachable'
                } # end object
            } Else {
				Write-Verbose("{0}: WARNING - Unreachable, skipping" -f $Computer)
			} # end if computer is reachable or not
        } # end foreach
		
		# Finally, loop over all the keys we've collected, displaying them
		foreach ( $obj in $aKeys ) {
			if ( $SkipOEMInfo ) {
				$obj | Select-Object -Property * -ExcludeProperty OEMManufacturer,OEMModel
			} Else {
				$obj
			}
		} # end foreach
    } # end process
} # end function 