// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

import {Artifact, Cmd, Tool, Transformer} from "Sdk.Transformers";

import {Shared, PlatformDependentQualifier} from "Sdk.Native.Shared";

import * as Mc from "Sdk.Native.Tools.Mc";

export declare const qualifier: PlatformDependentQualifier;

export function defaultTool(): Transformer.ToolDefinition {
    //TODO: Need to have a downloadable  package for the Windows SDk.
    Contract.fail("No default tool was provided");
    return undefined;
}

export const defaultEtwArguments: Arguments = Mc.defaultMcOptions.override<Arguments>({
    sources: [],
    codeGenerationType: CodeGenerationType.userMode,
    mofFileGeneration: false,
    managedNamespace: undefined,
    callUserFunction: false
});

/**
 * Controls the type of code that gets generated by the message compiler.
 */
@@public
export const enum CodeGenerationType {
    /** Generate a kernel mode header file. */
    @@Tool.option("-km")
    kernelMode,
    /** The code produced will be a C# non-static class. */
    @@Tool.option("-cs")
    managed,
    /** The code produced will be a C# static class. */
    @@Tool.option("-css")
    managedStatic,
    /** Generate a user mode header file. */
    @@Tool.option("-um")
    userMode,
    /** Generate logging interfaces projectable to JavaScript */
    @@Tool.option("-generateProjections")
    winRT
}

/**
 * The arguments to mc.exe.
 */
@@public
export interface Arguments extends EtwManifestOptions, Transformer.RunnerArguments {
    /** The list of manifest files to compile. */
    sources?: Shared.SourceFileArtifact[];
}

/**
 * The message text file compiler options.
 */
@@public
export interface EtwManifestOptions extends Mc.McOptions {
    /** Controls whether the logging service code generated will call a user-defined function for each event. */
    @@Tool.option("-co")
    callUserFunction?: boolean;

    /** Controls the type of code that gets generated by the message compiler. */
    codeGenerationType?: CodeGenerationType;

    /** The namespace to place the generated class in. */
    managedNamespace?: string;

    /** Override for the default prefix (EventWrite) that the compiler uses for the logging macro names and method names. */
    @@Tool.option("-p", { optionSeparationMode: Tool.OptionSeparationMode.required, optionSeparator: " " })
    methodPrefix?: string;

    /** Managed Object Format (MOF) file generation. */
    @@Tool.option("-mof")
    mofFileGeneration?: boolean;

    /**
     * Prefix to remove from the Symbol Names when generating the logging macro names and method names.
     * The names are computed by taking the symbol name, removing this value and appending to it the MethodPrefix.
     */
    @@Tool.option("-P", { optionSeparationMode: Tool.OptionSeparationMode.required, optionSeparator: " " })
    removeSymbolPrefix?: string;

    /** Validate the contents of the source against a baseline. */
    @@Tool.option("-t", { optionSeparationMode: Tool.OptionSeparationMode.required, optionSeparator: " " })
    validationFile?: File;
}

/**
 * The value produced by the Mc transformer.
 */
@@public
export interface Result {
    /**
     * List of binary resource files that contains one resource file for each language
     * specified in the manifest.
     */
    binaryResources?: StaticDirectory;

    /**
     * The C# file (.cs) generated from the message text file
     * that contains the event descriptors, provider GUID, and symbol names to reference in the application.
     */
    code: File;

    /** The C/C++ header file (.h) generated */
    header?: StaticDirectory;

    /** The MOF file generated for downlevel compatibility. */
    mof: File;

    /** The resource compiler script that contains the statements to include each binary file as a resource. */
    resourceCompilerScript: File;

    /** WinRT source code to produce a version callable from WinRT and JavaScript. */
    winRT?: EtwWinRTOutput;
}

/**
 * All the code necessary to build a DLL that is callable from WinRT compliant language to log ETW events.
 */
@@public
export interface EtwWinRTOutput {
    /** The XML fragment that needs to be copied into an AppX manifest file. */
    appXManifest: File;

    /** The C++ source code. */
    code: File;

    /** The C++ header file. */
    header: File;

    /** The Interface Definition Langauge (idl) file. */
    idl: File;
}

/**
 * Determines if the SourceFileArtifact is an etw manifest file
 */
@@public
export function isEtwManFile(source: Shared.SourceFileArtifact): boolean {
    return typeof source === "File" && (source as File).extension === a`.man`;
}

/**
 * The message compiler (mc.exe) is used to compile instrumentation manifests and
 * message text files to generate the resources files to which an application links.
 */
@@Tool.runner("mc.exe (etw manifest)")
@@public
export function compile(args: Arguments): Map<PathAtom, Result> {
    args = defaultEtwArguments.override<Arguments>(args);
    let results = args.sources.map((src, idx) => {
        let outDirName = "mc" + (args.sources.length === 1 ? "" : idx.toString());
        let outDir = Context.getNewOutputDirectory(outDirName);
        let fileBasename = args.baseFileName || Shared.getFile(src).nameWithoutExtension;
        let isManagedCodeGen = args.codeGenerationType === CodeGenerationType.managed;

        let codeOutFile = isManagedCodeGen ? outDir.combine(fileBasename.changeExtension(args.fileNameExtension || ".css")) : undefined;
        let headerOutFile = isManagedCodeGen ? undefined : outDir.combine(fileBasename.changeExtension(args.fileNameExtension || ".h"));
        let theOutFile = codeOutFile || headerOutFile;
        Contract.assert(theOutFile !== undefined);

        let mofOutFile = args.mofFileGeneration ? theOutFile.changeExtension(".mof") : undefined;
        let rcOutFile = theOutFile.changeExtension(".rc");

        let binOutFiles: Path[] = [
            outDir.combine(fileBasename.concat("TEMP").changeExtension(".bin")),
            ...nTimes(max(args.languagesCount || 0, 1), (i => {
                let baseMsgFileName = "MSG" + Shared.prepend("0", 5, (i+1).toString()); // this is toString("D5") in C#
                let languageBaseName = args.baseFileName ? args.baseFileName.toString() + "_" + baseMsgFileName : baseMsgFileName;
                return outDir.combine(languageBaseName).changeExtension(".bin");
            }))
            //BuildCacheEvents_MSG00001.bin
        ];
        
        let winRTFiles = args.codeGenerationType === CodeGenerationType.winRT ? [
            outDir.combine("winRTProvider.cpp"),
            outDir.combine("winRTProvider.hpp"),
            outDir.combine("winRTProvider.idl"),
            outDir.combine("AppXExtension.xml"),
        ] : [];

        let etwArgs: Argument[] = [
            // options
            Cmd.option("-r ", Artifact.none(outDir)),
            Cmd.option("-h ", Artifact.none(outDir)),
            Cmd.option("-z ", args.baseFileName, args.baseFileName !== undefined),
            Cmd.flag("-c", args.customerBit),
            Cmd.option("-m ", args.maximumMessageLength, args.maximumMessageLength !== 0),
            Cmd.option("-t ", Artifact.input(args.validationFile)),
            Cmd.flag("-generateProjections", args.codeGenerationType === CodeGenerationType.winRT),
            Cmd.flag("-um", args.codeGenerationType === CodeGenerationType.userMode),
            Cmd.flag("-km", args.codeGenerationType === CodeGenerationType.kernelMode),
            Cmd.flag("-cs", args.codeGenerationType === CodeGenerationType.managed),
            Cmd.flag("-css", args.codeGenerationType === CodeGenerationType.managedStatic),
            Cmd.argument(args.managedNamespace),
            Cmd.flag("-co", args.callUserFunction && [CodeGenerationType.userMode, CodeGenerationType.kernelMode].some(e => e === args.codeGenerationType)),
            Cmd.flag("-mof", args.mofFileGeneration && args.codeGenerationType !== CodeGenerationType.winRT),
            Cmd.option("-P ", args.removeSymbolPrefix, args.removeSymbolPrefix !== ""),

            // outputs: all implicit
            // inputs                
            Cmd.argument(Artifact.input(Shared.getFile(src))),
        ];

        let outputs = Transformer.execute({
            tool: Shared.applyToolDefaults(args.tool || defaultTool()),
            workingDirectory: outDir,
            arguments: etwArgs,
            implicitOutputs: compress([
                theOutFile,
                mofOutFile,
                rcOutFile,
                ...binOutFiles,
                ...winRTFiles,
            ]),
        });

        let binFiles = Transformer.sealDirectory({
            root: d`${rcOutFile.parent}`, 
            files: binOutFiles.map(f => outputs.getOutputFile(f))
        });
        let result = <Result>{
            code:                   codeOutFile && outputs.getOutputFile(codeOutFile),
            header:                 Transformer.sealDirectory({
                root: d`${headerOutFile.parent}`, 
                files: [outputs.getOutputFile(headerOutFile)]
            }),
            binaryResources:        binFiles,
            resourceCompilerScript: outputs.getOutputFile(rcOutFile),
            mof:                    outputs.getOutputFile(mofOutFile),
            winRT:                  winRTFiles.length > 0 ? <EtwWinRTOutput> {
                                        code: outputs.getOutputFile(winRTFiles[0]),
                                        header: outputs.getOutputFile(winRTFiles[1]),
                                        idl: outputs.getOutputFile(winRTFiles[2]),
                                        appXManifest: outputs.getOutputFile(winRTFiles[3]),
                                    } : undefined
        };

        let srcPathAtom = Shared.getFile(src).name;
        return <[PathAtom, Result]>[srcPathAtom, result];
    });

    return Map.empty<PathAtom, Result>().addRange(...results);
}

function max(a: number, b: number): number {
    return a > b ? a : b;
}

function nTimes<T>(n: number, fn: (i: number) => T): T[] {
    return n === 0
        ? []
        : [...nTimes(n - 1, fn), fn(n - 1)];
}

function compress<T>(a: T[]): T[] {
    return a.filter(e => e !== undefined);
}
