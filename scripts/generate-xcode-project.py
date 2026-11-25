"""Generate the dependency-free native app project; keep all paths repository-relative."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent
project = root / "TrioPC.xcodeproj"
project.mkdir(exist_ok=True)
objects = []

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def obj(name, value):
    objects.append(f"{ident(name)} = {{ {value} }};")
    return ident(name)

sources = []
file_refs = []
for path in sorted((root / "Sources/TrioPC").glob("*.swift")):
    relative = path.relative_to(root).as_posix()
    ref = obj(relative, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{relative}"; sourceTree = "<group>";')
    file_refs.append(ref)
    sources.append(obj("build:" + relative, f"isa = PBXBuildFile; fileRef = {ref};"))

product = obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = TrioPC.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj("products", f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
group = obj("group", f'isa = PBXGroup; children = ({",".join(file_refs)},{products},); sourceTree = "<group>";')
package = obj("package", 'isa = XCLocalSwiftPackageReference; relativePath = .;')
dependency = obj("core", f'isa = XCSwiftPackageProductDependency; package = {package}; productName = TrioCore;')
framework = obj("core-build", f'isa = PBXBuildFile; productRef = {dependency};')
frameworks = obj("frameworks", f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({framework},); runOnlyForDeploymentPostprocessing = 0;')
source_phase = obj("sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(sources)},); runOnlyForDeploymentPostprocessing = 0;')
resources = obj("resources", 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')

configs = []
project_configs = []
for name in ["Debug", "Release"]:
    env = "development" if name == "Debug" else "production"
    optimization = "-Onone" if name == "Debug" else "-O"
    active_arch = "YES" if name == "Debug" else "NO"
    settings = f'''
APS_ENVIRONMENT = {env}; CODE_SIGN_ENTITLEMENTS = Resources/TrioPC.entitlements;
CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = ""; ENABLE_HARDENED_RUNTIME = YES;
GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Resources/Info.plist;
PRODUCT_BUNDLE_IDENTIFIER = com.fishistick.TrioPC; PRODUCT_NAME = "$(TARGET_NAME)";
MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_VERSION = 6.0;
SWIFT_STRICT_CONCURRENCY = complete; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
ONLY_ACTIVE_ARCH = {active_arch};
SWIFT_OPTIMIZATION_LEVEL = "{optimization}";
'''
    configs.append(obj("config:" + name, f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {name};'))
    project_configs.append(obj("project-config:" + name, f'isa = XCBuildConfiguration; buildSettings = {{ CLANG_ENABLE_MODULES = YES; }}; name = {name};'))

config_list = obj("configs", f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project_config_list = obj("project-configs", f'isa = XCConfigurationList; buildConfigurations = ({",".join(project_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj("target", f'isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = ({source_phase},{frameworks},{resources},); buildRules = (); dependencies = (); name = TrioPC; packageProductDependencies = ({dependency},); productName = TrioPC; productReference = {product}; productType = "com.apple.product-type.application";')
project_id = obj("project", f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; TargetAttributes = {{ {target} = {{ CreatedOnToolsVersion = 16.0; SystemCapabilities = {{ com.apple.Push = {{ enabled = 1; }}; }}; }}; }}; }}; buildConfigurationList = {project_config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {group}; packageReferences = ({package},); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
(project / "project.pbxproj").write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + "\n".join(objects) + f'\n}}; rootObject = {project_id}; }}\n')
schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "TrioPC.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TrioPC.app" BlueprintName="TrioPC" ReferencedContainer="container:TrioPC.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TrioPC.app" BlueprintName="TrioPC" ReferencedContainer="container:TrioPC.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated TrioPC.xcodeproj")
