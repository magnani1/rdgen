using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using Microsoft.Win32;

internal static class DS790WNInstall
{
    static string Base = AppDomain.CurrentDomain.BaseDirectory;
    static string Logs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"TJPB\WinGet\DS790WN");
    static bool Restart;
    // Order: model driver, Scan OCR, DCP, Event Manager, OCR Pro, EpsonNet.
    static bool[] Components()
    {
        return new[]{Scan2Installed(), Installed("EPSON Scan OCR Component","3.0.6"),
            Installed("Document Capture Pro","3.3.25"), Installed("Epson Event Manager","3.11.86"),
            Installed("Epson Scan OCR Component Pro","1.1.2"), Installed("EpsonNet Config V4","4.9.11")};
    }
    static string[] PlanSteps(bool[] components, bool reapplyProfile)
    {
        Require(components!=null && components.Length==6,"Incomplete component inventory.");
        var steps=new List<string>();
        if(!components[0]) steps.Add("Scan2");
        if(!components[1]) steps.Add("ScanOCR");
        if(!components[2] || !components[3] || !components[4] || reapplyProfile) steps.Add("DCP");
        if(!components[5]) steps.Add("EpsonNet");
        return steps.ToArray();
    }
    static bool HasOption(string[] args,string option)
    {
        return Array.Exists(args,a=>a.Equals(option,StringComparison.OrdinalIgnoreCase));
    }
    static void Log(string message) { File.AppendAllText(Path.Combine(Logs,"installation.log"), DateTime.Now.ToString("s")+" "+message+Environment.NewLine); }
    static bool Installed(string name, string minimum)
    {
        foreach (RegistryView view in new[]{RegistryView.Registry32,RegistryView.Registry64})
        using (RegistryKey root=RegistryKey.OpenBaseKey(RegistryHive.LocalMachine,view))
        using (RegistryKey uninstall=root.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"))
        {
            if (uninstall==null) continue;
            foreach (string id in uninstall.GetSubKeyNames()) using(RegistryKey key=uninstall.OpenSubKey(id))
            {
                if(key==null || !String.Equals(Convert.ToString(key.GetValue("DisplayName")),name,StringComparison.OrdinalIgnoreCase)) continue;
                Version version;
                if(Version.TryParse(Convert.ToString(key.GetValue("DisplayVersion")),out version) && version>=new Version(minimum)) return true;
            }
        }
        return false;
    }
    static bool Scan2Installed()
    {
        string info=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),@"epson\Epson Scan 2\Models\ES0246\verinfo.esi");
        if(!File.Exists(info)) return false;
        Match match=Regex.Match(File.ReadAllText(info),@"(?im)^\s*DriverVer\s*=\s*[^,]+,\s*(\d+\.\d+\.\d+\.\d+)\s*$");
        Version version;
        if(!match.Success || !Version.TryParse(match.Groups[1].Value,out version) || version<new Version("6.7.81.0")) return false;
        foreach(string folder in new[]{Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86)})
            if(Directory.Exists(Path.Combine(folder,@"epson\Epson Scan 2\Drivers\ES0246"))) return true;
        return false;
    }
    static void Run(string relative, string arguments)
    {
        string exe=Path.IsPathRooted(relative)?relative:Path.Combine(Base,relative);
        Log("Starting "+relative+" "+arguments);
        var start=new ProcessStartInfo(exe,arguments){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=Path.GetDirectoryName(exe)};
        int result;
        using(var process=Process.Start(start)){process.WaitForExit();result=process.ExitCode;}
        Log("Exit code: "+result);
        if(result==3010) Restart=true;
        else if(result!=0) throw new InvalidOperationException(relative+" exited with "+result);
    }
    static void Msi(string relative)
    {
        string log=Path.Combine(Logs,Path.GetFileNameWithoutExtension(relative)+"-"+DateTime.Now.ToString("yyyyMMddHHmmss")+".log");
        Run(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"msiexec.exe"),"/i \""+Path.Combine(Base,relative)+"\" /qn /norestart ALLUSERS=1 /L*v \""+log+"\"");
    }
    static void Require(bool condition,string message){if(!condition) throw new InvalidOperationException(message);}
    static string ScannerArgument(string[] args)
    {
        string result=null;
        for(int index=0;index<args.Length;index++)
        {
            string value=null;
            if(args[index].Equals("--nome",StringComparison.OrdinalIgnoreCase) || args[index].Equals("/nome",StringComparison.OrdinalIgnoreCase))
            {
                Require(index+1<args.Length,"--nome requires the scanner DNS hostname.");
                value=args[++index];
            }
            else if(args[index].StartsWith("--nome=",StringComparison.OrdinalIgnoreCase)) value=args[index].Substring(7);
            if(value==null) continue;
            Require(result==null,"Specify --nome only once.");
            result=value.Trim().TrimEnd('.');
            Require(Regex.IsMatch(result,@"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"),"Invalid scanner hostname.");
        }
        return result;
    }
    static bool FindScanner(object node,string hostname)
    {
        var dictionary=node as Dictionary<string,object>;
        if(dictionary!=null)
        {
            object addressNode,modelNode;
            if(dictionary.TryGetValue("ipAddress",out addressNode) && dictionary.TryGetValue("scannerID",out modelNode))
            {
                var address=addressNode as Dictionary<string,object>;
                var model=modelNode as Dictionary<string,object>;
                object addressValue,modelValue;
                if(address!=null && model!=null && address.TryGetValue("string",out addressValue) && model.TryGetValue("string",out modelValue)
                    && String.Equals(Convert.ToString(modelValue),"ES0246",StringComparison.OrdinalIgnoreCase)
                    && String.Equals(Convert.ToString(addressValue).TrimEnd('.'),hostname,StringComparison.OrdinalIgnoreCase)) return true;
            }
            foreach(object value in dictionary.Values) if(FindScanner(value,hostname)) return true;
        }
        else if(node is IEnumerable && !(node is string)) foreach(object value in (IEnumerable)node) if(FindScanner(value,hostname)) return true;
        return false;
    }
    static bool ScannerRegistered(string path,string hostname)
    {
        if(!File.Exists(path)) return false;
        var serializer=new JavaScriptSerializer();serializer.MaxJsonLength=16*1024*1024;
        return FindScanner(serializer.DeserializeObject(File.ReadAllText(path)),hostname);
    }
    static void RegisterScanner(string hostname)
    {
        Require(Scan2Installed(),"Install Epson Scan 2 and the DS-790WN driver before registering the scanner.");
        Require(Dns.GetHostAddresses(hostname).Length>0,"Scanner hostname did not resolve in DNS.");
        string connection=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),@"epson\Epson Scan 2\Connection\ConnectInfo.dat");
        if(ScannerRegistered(connection,hostname)){Log("Scanner already registered for the machine by hostname: "+hostname+"; no duplicate added.");return;}
        string utility=null;
        foreach(string folder in new[]{Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)})
        {
            string candidate=Path.Combine(folder,@"epson\Epson Scan 2\Core\es2utility.exe");
            if(File.Exists(candidate)){utility=candidate;break;}
        }
        Require(utility!=null,"Epson Scan 2 Utility was not found.");
        if(File.Exists(connection))
        {
            string backup=Path.Combine(Logs,"ConnectInfo-before-"+DateTime.Now.ToString("yyyyMMddHHmmss")+"-"+Guid.NewGuid().ToString("N")+".dat");
            File.Copy(connection,backup);Log("Scanner configuration backup: "+backup);
        }
        Run(utility,"/ADD ID ES0246 FQDN \""+hostname+"\"");
        Require(ScannerRegistered(connection,hostname),"Epson Utility did not persist the scanner DNS hostname.");
        Log("Scanner registered for the machine with its DNS hostname: "+hostname);
    }
    static void InstallDesktopShortcuts()
    {
        string programs=Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms);
        string desktop=Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory);
        string[] shortcuts={@"EPSON\Epson Scan 2\Epson Scan 2 Utility.lnk",@"EPSON\Epson Scan 2\Epson Scan 2.lnk",@"EPSON Software\Document Capture Pro.lnk"};
        foreach(string shortcut in shortcuts) Require(File.Exists(Path.Combine(programs,shortcut)),"Missing Start Menu shortcut: "+shortcut);
        Directory.CreateDirectory(desktop);
        foreach(string shortcut in shortcuts)
        {
            string source=Path.Combine(programs,shortcut);
            string destination=Path.Combine(desktop,Path.GetFileName(shortcut));
            File.Copy(source,destination,true);
            Log("Public desktop shortcut: "+destination);
        }
    }
    static void ConfigurePushScanFirewall()
    {
        string program=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),@"Epson Software\Event Manager\EEventManager.exe");
        Require(File.Exists(program),"EEventManager.exe is missing; cannot configure its firewall rules.");
        Type policyType=Type.GetTypeFromProgID("HNetCfg.FwPolicy2");
        object policy=Activator.CreateInstance(policyType);
        object rules=policyType.InvokeMember("Rules",System.Reflection.BindingFlags.GetProperty,null,policy,null);
        foreach(string protocol in new[]{"TCP","UDP"})
        {
            string name="TJPB Epson DS-790WN Push Scan "+protocol;
            object rule;
            try { rule=rules.GetType().InvokeMember("Item",System.Reflection.BindingFlags.GetProperty,null,rules,new object[]{name}); }
            catch { rule=Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FWRule")); }
            Action<string,object> set=(property,value)=>rule.GetType().InvokeMember(property,System.Reflection.BindingFlags.SetProperty,null,rule,new object[]{value});
            set("Name",name); set("Description","Epson Event Manager push scanning on the domain network.");
            set("ApplicationName",program); set("Protocol",protocol=="TCP"?6:17); set("LocalPorts","2968");
            set("Direction",1); set("Action",1); set("Profiles",1); set("Enabled",true);
            // Add replaces a same-named rule; only this package's rules are managed.
            rules.GetType().InvokeMember("Add",System.Reflection.BindingFlags.InvokeMethod,null,rules,new[]{rule});
            Log("Firewall: "+name+"; domain profile; inbound port 2968; program="+program);
        }
    }
    [STAThread] static int Main(string[] args)
    {
        try
        {
            bool[] components=Components();
            if(HasOption(args,"/check"))
            {
                File.WriteAllText(Path.Combine(Base,"diagnostic.txt"),"Scan2/model="+components[0]+"; OCR="+components[1]+"; DCP="+components[2]+"; EventManager="+components[3]+"; OCRPro="+components[4]+"; EpsonNet="+components[5]+Environment.NewLine);
                return PlanSteps(components,false).Length==0?0:2;
            }
            if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) return 740;
            // Each execution has its own logs; no shared append-only result file.
            Logs=Path.Combine(Logs,"runs",DateTime.Now.ToString("yyyyMMddTHHmmss")+"-"+Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Logs);
            string hostname=ScannerArgument(args);
            if(hostname!=null) hostname=hostname.ToUpperInvariant();
            if(HasOption(args,"/shortcuts")) {InstallDesktopShortcuts();return 0;}
            if(HasOption(args,"/configure-only")) {Require(hostname!=null,"Specify --nome for /configure-only.");RegisterScanner(hostname);return 0;}
            // Resolve before starting installers. This checks DNS, not scanner health.
            if(hostname!=null) Require(Dns.GetHostAddresses(hostname).Length>0,"Scanner hostname did not resolve in DNS.");
            bool reapply=HasOption(args,"/reapply-profile");
            string[] steps=PlanSteps(components,reapply);
            Log("Package 2026.11.5.1; required installation steps: "+String.Join(", ",steps));
            foreach(string step in steps)
            {
                if(step=="Scan2")
                {
                    Run(@"Scan2\Setup.exe","/SI /NODISP /NOLA");
                    Require(Scan2Installed(),"Epson Scan 2 or DS-790WN model was not registered. See Epson setup log.");
                }
                else if(step=="ScanOCR")
                {
                    Msi(@"ScanOCR\OCRComponent.msi");
                    Require(Installed("EPSON Scan OCR Component","3.0.6"),"Scan OCR was not registered.");
                }
                else if(step=="DCP")
                {
                    // Only missing components or explicit profile reapplication run
                    // Epson's official deployment helper. Never ignore its errors.
                    Run(@"DCP\Setup.exe","/quiet");
                    Require(Installed("Document Capture Pro","3.3.25"),"Document Capture Pro was not registered.");
                    Require(Installed("Epson Event Manager","3.11.86"),"Epson Event Manager was not registered.");
                    Require(Installed("Epson Scan OCR Component Pro","1.1.2"),"Document Capture Pro OCR was not registered.");
                }
                else if(step=="EpsonNet")
                {
                    Run(@"EpsonNet\TjpbInstall.exe","/quiet");
                    Require(Installed("EpsonNet Config V4","4.9.11"),"EpsonNet Config was not registered.");
                }
            }
            Require(PlanSteps(Components(),false).Length==0,"Required components are still missing or below their minimum versions.");
            if(steps.Length>0)
            {
                ConfigurePushScanFirewall();
                InstallDesktopShortcuts();
            }
            else Log("All required components meet the minimum versions; no installer, profile, firewall or shortcut changes requested.");
            if(hostname!=null) RegisterScanner(hostname);
            else Log("No scanner association requested; existing configuration preserved.");
            Log("Completed. Component presence and scanner registration do not confirm physical scanning or per-user preferences.");
            return Restart?3010:0;
        }
        catch(Exception error){try{Log(error.ToString());}catch{} return 1603;}
    }
}
