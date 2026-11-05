using System;
using System.Collections.Generic;
using System.Reflection;
using System.Web.Script.Serialization;
class TestPlan {
 static Type Launcher;
 static object Call(string name,params object[] args) {
  return Launcher.GetMethod(name,BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,args);
 }
 static void Assert(bool ok,string message) {if(!ok)throw new Exception(message);}
 static void Plan(bool[] state,bool reapply,string expected) {
  Assert(String.Join(",",(string[])Call("PlanSteps",state,reapply))==expected,"Unexpected plan: "+expected);
 }
 static int Main(string[] args) {
  try {
   Launcher=Assembly.LoadFrom(args[0]).GetType("DS790WNInstall",true);
   Plan(new[]{true,true,true,true,true,true},false,"");
   Plan(new[]{true,true,true,true,true,true},true,"DCP");
   Plan(new[]{false,false,false,false,false,false},false,"Scan2,ScanOCR,DCP,EpsonNet");
   Plan(new[]{true,true,true,false,true,true},false,"DCP");
   Plan(new[]{true,true,true,true,false,true},false,"DCP");
   Plan(new[]{true,false,true,true,true,true},false,"ScanOCR");
   Plan(new[]{true,true,true,true,true,false},false,"EpsonNet");
   // All 64 inventories: each missing member of the DCP group requires DCP.
   for(int mask=0;mask<64;mask++) {
    var state=new bool[6];for(int i=0;i<6;i++)state[i]=(mask&(1<<i))!=0;
    string[] steps=(string[])Call("PlanSteps",state,false);
    Assert(Array.IndexOf(steps,"DCP")>=0==(!state[2]||!state[3]||!state[4]),"DCP completeness");
    Assert((steps.Length==0)==(mask==63),"Only complete inventory can skip installation");
   }
   string host=(string)Call("ScannerArgument",new object[]{new[]{"/quiet","--nome","epson.example.test."}});
   Assert(host=="epson.example.test","Hostname parsing");
   foreach(string bad in new[]{"https://epson.test","epson;whoami","-bad.test","a..test"}) {
    bool rejected=false;try{Call("ScannerArgument",new object[]{new[]{"--nome",bad}});}catch(TargetInvocationException){rejected=true;}
    Assert(rejected,"Invalid hostname accepted");
   }
   var entry=new Dictionary<string,object>{
    {"ipAddress",new Dictionary<string,object>{{"string","EPSon.example.test."}}},
    {"scannerID",new Dictionary<string,object>{{"string","ES0246"}}}
   };
   Assert((bool)Call("FindScanner",entry,"epson.example.test"),"Case/trailing-dot duplicate");
   Assert(!(bool)Call("FindScanner",entry,"different.example.test"),"Different scanner mistaken for same");
   ((Dictionary<string,object>)entry["scannerID"])["string"]="OTHER";
   Assert(!(bool)Call("FindScanner",entry,"epson.example.test"),"Wrong model accepted");
   Console.WriteLine("64 inventories; missing DCP children; profile opt-in; DNS validation and duplicate detection: OK. No installers executed.");
   return 0;
  } catch(Exception e) {Console.Error.WriteLine(e);return 1;}
 }
}
