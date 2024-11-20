// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart';

enum Target {
  windows,
  linux,
  android,
  macos,
}

extension TargetExt on Target {
  String get os {
    if (this == Target.macos) {
      return "darwin";
    }
    return name;
  }

  String get dynamicLibExtensionName {
    final String extensionName;
    switch (this) {
      case Target.android || Target.linux:
        extensionName = ".so";
        break;
      case Target.windows:
        extensionName = ".dll";
        break;
      case Target.macos:
        extensionName = ".dylib";
        break;
    }
    return extensionName;
  }

  String get executableExtensionName {
    final String extensionName;
    switch (this) {
      case Target.windows:
        extensionName = ".exe";
        break;
      default:
        extensionName = "";
        break;
    }
    return extensionName;
  }
}

enum Mode { core, lib }

enum Arch { amd64, arm64, arm }

class BuildItem {
  Target target;
  Arch? arch;
  String? archName;

  BuildItem({
    required this.target,
    this.arch,
    this.archName,
  });

  @override
  String toString() {
    return 'BuildLibItem{target: $target, arch: $arch, archName: $archName}';
  }
}

class Build {
  static List<BuildItem> get buildItems => [
        BuildItem(
          target: Target.macos,
        ),
        BuildItem(
          target: Target.windows,
        ),
        BuildItem(
          target: Target.linux,
        ),
        BuildItem(
          target: Target.android,
          arch: Arch.arm,
          archName: 'armeabi-v7a',
        ),
        BuildItem(
          target: Target.android,
          arch: Arch.arm64,
          archName: 'arm64-v8a',
        ),
        BuildItem(
          target: Target.android,
          arch: Arch.amd64,
          archName: 'x86_64',
        ),
      ];

  static String get appName => "FlClash";

  static String get name => "clash";

  static String get libName => "lib$name";

  static String get outDir => join(current, libName);

  static String get _coreDir => join(current, "core");

  static String get _servicesDir => join(current, "services", "helper");

  static String get distPath => join(current, "dist");

  static String _getCc(BuildItem buildItem) {
    final environment = Platform.environment;
    if (buildItem.target == Target.android) {
      final ndk = environment["ANDROID_NDK"];
      assert(ndk != null);
      final prebuiltDir =
          Directory(join(ndk!, "toolchains", "llvm", "prebuilt"));
      final prebuiltDirList = prebuiltDir.listSync();
      final map = {
        "armeabi-v7a": "armv7a-linux-androideabi21-clang",
        "arm64-v8a": "aarch64-linux-android21-clang",
        "x86": "i686-linux-android21-clang",
        "x86_64": "x86_64-linux-android21-clang"
      };
      return join(
        prebuiltDirList.first.path,
        "bin",
        map[buildItem.archName],
      );
    }
    return "gcc";
  }

  static get tags => "with_gvisor";

  static Future<void> exec(
    List<String> executable, {
    String? name,
    Map<String, String>? environment,
    String? workingDirectory,
    bool runInShell = true,
  }) async {
    if (name != null) print("run $name");
    final process = await Process.start(
      executable[0],
      executable.sublist(1),
      environment: environment,
      workingDirectory: workingDirectory,
      runInShell: runInShell,
    );
    process.stdout.listen((data) {
      print(utf8.decode(data));
    });
    process.stderr.listen((data) {
      print(utf8.decode(data));
    });
    final exitCode = await process.exitCode;
    if (exitCode != 0 && name != null) throw "$name error";
  }

  static buildCore({
    required Mode mode,
    required Target target,
    Arch? arch,
  }) async {
    final isLib = mode == Mode.lib;

    final items = buildItems.where(
      (element) {
        return element.target == target &&
            (arch == null ? true : element.arch == arch);
      },
    ).toList();

    for (final item in items) {
      final outFileDir = join(
        outDir,
        item.target.name,
        item.archName,
      );

      final file = File(outFileDir);
      if (file.existsSync()) {
        file.deleteSync(recursive: true);
      }

      final fileName = isLib
          ? "$libName${item.target.dynamicLibExtensionName}"
          : "$name${item.target.executableExtensionName}";
      final outPath = join(
        outFileDir,
        fileName,
      );

      final Map<String, String> env = {};
      env["GOOS"] = item.target.os;

      if (isLib) {
        if (item.arch != null) {
          env["GOARCH"] = item.arch!.name;
        }
        env["CGO_ENABLED"] = "1";
        env["CC"] = _getCc(item);
        env["CFLAGS"] = "-O3 -Werror";
      }

      final execLines = [
        "go",
        "build",
        "-ldflags=-w -s",
        "-tags=$tags",
        if (isLib) "-buildmode=c-shared",
        "-o",
        outPath,
      ];
      await exec(
        execLines,
        name: "build core",
        environment: env,
        workingDirectory: _coreDir,
      );
    }
  }

  static buildHelper(Target target) async {
    await exec(
      [
        "cargo",
        "build",
        "--release",
      ],
      name: "build helper",
      workingDirectory: _servicesDir,
    );
    final outPath = join(
      _servicesDir,
      "target",
      "release",
      "helper${target.executableExtensionName}",
    );
    final targetPath = join(outDir, target.name,
        "FlClashHelperService${target.executableExtensionName}");
    await File(outPath).copy(targetPath);
  }

  static List<String> getExecutable(String command) {
    print(command);
    return command.split(" ");
  }

  static getDistributor() async {
    final distributorDir = join(
      current,
      "plugins",
      "flutter_distributor",
      "packages",
      "flutter_distributor",
    );

    await exec(
      name: "clean distributor",
      Build.getExecutable("flutter clean"),
      workingDirectory: distributorDir,
    );
    await exec(
      name: "get distributor",
      Build.getExecutable("dart pub global activate -s path $distributorDir"),
    );
  }

  static copyFile(String sourceFilePath, String destinationFilePath) {
    final sourceFile = File(sourceFilePath);
    if (!sourceFile.existsSync()) {
      throw "SourceFilePath not exists";
    }
    final destinationFile = File(destinationFilePath);
    final destinationDirectory = destinationFile.parent;
    if (!destinationDirectory.existsSync()) {
      destinationDirectory.createSync(recursive: true);
    }
    try {
      sourceFile.copySync(destinationFilePath);
      print("File copied successfully!");
    } catch (e) {
      print("Failed to copy file: $e");
    }
  }
}

class BuildCommand extends Command {
  Target target;

  BuildCommand({
    required this.target,
  }) {
    if (target == Target.android) {
      argParser.addOption(
        "arch",
        valueHelp: arches.map((e) => e.name).join(','),
        help: 'The $name build desc',
      );
    } else {
      argParser.addOption(
        "arch",
        help: 'The $name build archName',
      );
    }

    argParser.addOption(
      "out",
      valueHelp: [
        "app",
        "core",
      ].join(','),
      help: 'The $name build arch',
    );
  }

  @override
  String get description => "build $name application";

  @override
  String get name => target.name;

  List<Arch> get arches => Build.buildItems
      .where((element) => element.target == target && element.arch != null)
      .map((e) => e.arch!)
      .toList();

  _getLinuxDependencies() async {
    await Build.exec(
      Build.getExecutable("sudo apt update -y"),
    );
    await Build.exec(
      Build.getExecutable("sudo apt install -y ninja-build libgtk-3-dev"),
    );
    await Build.exec(
      Build.getExecutable("sudo apt install -y libayatana-appindicator3-dev"),
    );
    await Build.exec(
      Build.getExecutable("sudo apt install -y rpm patchelf"),
    );
    await Build.exec(
      Build.getExecutable("sudo apt-get install -y libkeybinder-3.0"),
    );
    await Build.exec(
      Build.getExecutable("sudo apt install -y locate"),
    );
    await Build.exec(
      Build.getExecutable("sudo apt install -y libfuse2"),
    );
    await Build.exec(
      Build.getExecutable(
        "wget -O appimagetool https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage",
      ),
    );
    await Build.exec(
      Build.getExecutable(
        "chmod +x appimagetool",
      ),
    );
    await Build.exec(
      Build.getExecutable(
        "sudo mv appimagetool /usr/local/bin/",
      ),
    );
  }

  _getMacosDependencies() async {
    await Build.exec(
      Build.getExecutable("npm install -g appdmg"),
    );
  }

  _buildDistributor({
    required Target target,
    required String targets,
    String args = '',
  }) async {
    await Build.getDistributor();
    await Build.exec(
      name: name,
      Build.getExecutable(
        "flutter_distributor package --skip-clean --platform ${target.name} --targets $targets --flutter-build-args=verbose $args",
      ),
    );
  }

  Future<String?> get systemArch async {
    if (Platform.isWindows) {
      return Platform.environment["PROCESSOR_ARCHITECTURE"];
    } else if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('uname', ['-m']);
      return result.stdout.toString().trim();
    }
    return null;
  }

  @override
  Future<void> run() async {
    final mode = target == Target.android ? Mode.lib : Mode.core;
    final String out = argResults?['out'] ?? 'app';
    Arch? arch;
    var archName = argResults?['arch'];

    if (target == Target.android) {
      final currentArches =
          arches.where((element) => element.name == archName).toList();
      arch = currentArches.isEmpty ? null : currentArches.first;
      if (arch == null) {
        throw "Invalid arch";
      }
    }

    await Build.buildCore(
      target: target,
      arch: arch,
      mode: mode,
    );

    if (target == Target.windows) {
      await Build.buildHelper(target);
    }

    if (out != "app") {
      return;
    }

    switch (target) {
      case Target.windows:
        _buildDistributor(
          target: target,
          targets: "exe,zip",
          args: "--description $archName",
        );
      case Target.linux:
        await _getLinuxDependencies();
        _buildDistributor(
          target: target,
          targets: "appimage,deb,rpm",
          args: "--description $archName",
        );
      case Target.android:
        final targetMap = {
          Arch.arm: "android-arm",
          Arch.arm64: "android-arm64",
          Arch.amd64: "android-x64",
        };
        final defaultArches = [Arch.arm, Arch.arm64, Arch.amd64];
        final defaultTargets = defaultArches
            .where((element) => arch == null ? true : element == arch)
            .map((e) => targetMap[e])
            .toList();
        _buildDistributor(
          target: target,
          targets: "apk",
          args:
              "--flutter-build-args split-per-abi --build-target-target ${defaultTargets.join(",")}",
        );
      case Target.macos:
        await _getMacosDependencies();
        _buildDistributor(
          target: target,
          targets: "dmg",
          args: "--description $archName",
        );
    }
  }
}

main(args) async {
  final runner = CommandRunner("setup", "build Application");
  runner.addCommand(BuildCommand(target: Target.android));
  if (Platform.isWindows) {
    runner.addCommand(BuildCommand(target: Target.windows));
  }
  if (Platform.isLinux) {
    runner.addCommand(BuildCommand(target: Target.linux));
  }
  if (Platform.isMacOS) {
    runner.addCommand(BuildCommand(target: Target.macos));
  }
  runner.run(args);
}
