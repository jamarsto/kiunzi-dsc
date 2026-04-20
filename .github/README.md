# Kiunzi Desired State Configuration (DSC)

## Project Overview

This project provisions a Windows development workstation using PowerShell DSC so every machine is configured the same way.

It validates, installs, and fixes the required dependencies for building and deploying microservices on Kubernetes.

You can run it in two modes:

1. Plan (dry run): shows what is already installed and what still needs to be installed or corrected.
2. Apply: enforces the full desired configuration automatically.

## What this setup installs and configures

### Platform Prerequisites

1. Virtual Machine Platform
2. Windows Subsystem for Linux (WSL)
3. Hyper-V (when supported by the Windows edition)

### Package Management

1. Chocolatey (with optional package library relocation to a data drive)

### Developer Tools (Windows)

1. Visual Studio Code
2. IntelliJ IDEA Community Edition
3. Git
4. Terraform
5. Temurin Java 25 JDK
6. Machine-level JAVA_HOME
7. Docker Desktop
8. Kubeseal (Sealed Secrets CLI)

### Kubernetes Readiness

1. Docker Desktop Kubernetes is enabled to provide a local Kubernetes environment.

### WSL Ubuntu Toolchain

1. Ubuntu distribution installation
2. Git
3. Temurin Java 25 JDK
4. Exported JAVA_HOME
5. Mandrel Java 25 native-image toolchain
6. PATH updates for Mandrel binaries

## Summary

This repository is a workstation prerequisite enforcer for cloud-native development.

It ensures your environment is fully prepared to build, run, and deploy Java-based microservices on Kubernetes with consistent, repeatable setup across machines.

## Usage

### Prerequisites

Install cChoco (once):

```powershell
Install-Module cChoco -Repository PSGallery -Force
```

### Installation (ZIP-first)

Extract this repo (ZIP download) to e.g. C:\src\dsc-repo, then:

### Allow locally created scripts to run unsigned for this session

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### Dry run (default)

```powershell
.\Invoke-DevWorkstation.ps1
```

### Apply (interactive)

```powershell
.\Invoke-DevWorkstation.ps1 -Apply
```

Type YES to confirm (case-insensitive).

### Apply (CI / non-interactive)

```powershell
.\Invoke-DevWorkstation.ps1 -Apply -y
```

### Additional parameters

```powershell
.\Invoke-DevWorkstation.ps1 -Apply -y -DataDrive D: -IncludeChocoLibJunction
```

The ```DataDrive``` parameter extends installation and scanning to the data drive in addition to drive C:

The ```IncludeChocoLibJunction``` switch relocates the choco installation directory to the data drive

### Logs

Wrapper logs: logs\DevWorkstation-YYYYMMDD-HHMMSS.log
DSC logs (authoritative): Microsoft-Windows-Desired State Configuration / Operational and
C:\Windows\System32\Configuration\ConfigurationStatus
