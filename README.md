# Get-ProductKey
Powershell cmdlet to retrieve product keys and OS information from local or remote system/s.

Retrieves the product key and OS information from a local or remote system/s using WMI and/or ProduKey. Attempts to
decode the product key from the registry, shows product keys from SoftwareLicensingProduct (SLP), and attempts to use
ProduKey as well. Enables RemoteRegistry service if required.
Originally inspired by this script: https://gallery.technet.microsoft.com/scriptcenter/Get-product-keys-of-local-83b4ce97

Note that giving credentials with ProduKey requires running the process locally with those credentials, so they must
work on the local machine.

**.PARAMETER Computername**  
   Strings. Name of the local or remote system/s.
	
**.PARAMETER ShowOnlyValid**  
   Switch. Output only fully valid entries (pingable, has WMI access).

**.PARAMETER DontEnableRemoteRegistry**  
  Switch. Do NOT attempt to enable the RemoteRegistry service if it's disabled.

**.PARAMETER SkipRegProductKey**  
  Switch. Skip attempting to decode the product key from the registry (non-VLK/MAK only, requires RemoteRegistry if remote).

**.PARAMETER SkipOEMInfo**  
  Switch. Skip outputting OEM info from WMI / registry.

**.PARAMETER SkipProduKey**  
  Switch. Skip attempting to use ProduKey for additional keys (requires RemoteRegistry access for remote machines).

**.PARAMETER ProduKeyPath**  
  String. Path to ProduKey.exe, including name of executable. Default: ".\ProduKey.exe" (current directory)

**.PARAMETER PromptForCredentials**  
  Switch. Prompt for secure credentials to use.

**.PARAMETER Credential**  
  Secure credential object to use instead of the current user's credentials.

**.EXAMPLE**  
  PS> Get-ProductKey -Computername Computer1  

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
