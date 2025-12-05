# Azure Generation 2 VM Migration Guide

## Overview

Starting with Ubuntu Noble (24.04), BOSH Azure stemcells are being migrated to **Azure Generation 2 (Gen2) VM** architecture. This is a **breaking change** that requires understanding the differences and migration path.

## What's Changing

### Generation 2 VM Features

Azure Gen2 VMs provide modern virtualization features:

- **UEFI-based boot** (replaces legacy BIOS)
- **GPT partition table** (replaces MBR/MSDOS)
- **Fixed VHD format** (replaces dynamic VHD)
- **Trusted Launch support**:
  - vTPM (virtual Trusted Platform Module) - **Enabled**
  - Secure Boot - **Prepared but disabled** (packages installed for future enablement)
- **Accelerated Networking** support
- **SCSI disk controller** (recommended for Azure)

### Breaking Changes

1. **VM Generation**: Noble Azure stemcells use Gen2 only
   - Gen1 stemcells cannot be updated to Gen2 VMs
   - Requires redeployment of VMs using new stemcells

2. **Disk Format**: Changed from dynamic VHD to fixed VHD
   - Azure Gen2 requires fixed-size VHD format
   - VHDX format is not supported for Linux VMs in Azure
   - Fixed VHD provides better performance and compatibility

3. **Boot Architecture**: UEFI-only boot
   - Legacy BIOS boot removed
   - GPT partition table required

## Benefits

### Performance

- Faster boot times with UEFI
- Improved I/O performance with SCSI controller
- Accelerated networking support for better network throughput

### Security

- **vTPM enabled** for:
  - Cryptographic key protection
  - Secure attestation capabilities
  - Azure Disk Encryption support
  - BitLocker support (for future use)
- **Secure Boot ready**:
  - Packages installed: `shim-signed`, `grub-efi-amd64-signed`
  - Ubuntu Noble kernels are pre-signed
  - Can be enabled in future stemcell releases
- Boot integrity monitoring via Azure platform

### Modern Platform

- Supports latest Azure VM sizes and features
- Required for newer Azure capabilities
- Better long-term support from Azure

## Migration Path

### For New Deployments

Simply use the new Noble Gen2 stemcells - no additional steps required.

### For Existing Deployments (Gen1 → Gen2)

Since VMs cannot be upgraded from Gen1 to Gen2, you must redeploy:

1. **Prepare**:
   - Review your deployment manifests
   - Identify all VMs using Gen1 Azure stemcells
   - Plan maintenance window

2. **Update Stemcell**:

   ```bash
   bosh upload-stemcell <noble-azure-gen2-stemcell.tgz>
   ```

3. **Update Deployment Manifest**:

   ```yaml
   stemcells:
   - alias: default
     os: ubuntu-noble
     version: latest
   ```

4. **Deploy with Recreate**:

   ```bash
   bosh deploy -d <deployment> <manifest.yml> --recreate
   ```

   The `--recreate` flag ensures VMs are recreated with Gen2 architecture.

5. **Verify**:

   ```bash
   bosh vms -d <deployment>
   bosh instances -d <deployment> --vitals
   ```

### Rollback Plan

If issues occur, you can rollback to Gen1 stemcells:

1. Upload previous Gen1 stemcell version
2. Update manifest to reference Gen1 stemcell
3. Deploy with `--recreate`

**Note**: Keep Gen1 stemcells available during migration period.

## Trusted Launch Details

### vTPM (Enabled)

Virtual Trusted Platform Module is enabled by default:

- Provides hardware root of trust
- Supports cryptographic operations
- Enables secure attestation
- Required for certain Azure security features

**No configuration required** - works transparently.

### Secure Boot (Prepared, Disabled)

Secure Boot packages are pre-installed but the feature is disabled:

- **Installed packages**:
  - `shim-signed`: Microsoft-signed first-stage bootloader
  - `grub-efi-amd64-signed`: Signed GRUB2 bootloader
- **Kernel**: Ubuntu Noble kernels are pre-signed
- **Status**: `secure_boot_enabled: false` in stemcell metadata

**Why disabled?** Conservative approach for initial release. Will be enabled in future stemcell versions after validation.

## Technical Details

### Stemcell Metadata

Noble Azure stemcells include the following cloud properties:

```ruby
{
  'root_device_name' => '/dev/sda1',
  'generation' => 'gen2',                      # Gen2 VM
  'accelerated_networking' => true,            # Performance feature
  'hibernation' => true,                       # Hibernation support
  'disk_controller_types' => ['scsi'],         # Recommended for Azure
  'security_type' => 'TrustedLaunchSupported'  # Trusted Launch support
}
```

### Partition Layout

Gen2 stemcells use GPT partition table:

```
/dev/sda1: EFI System Partition (FAT32, 512MB, mounted at /boot/efi)
/dev/sda2: Root filesystem (ext4, remainder)
```

### Boot Process

1. Azure firmware loads UEFI
2. UEFI loads GRUB from EFI partition
3. GRUB loads Linux kernel
4. Kernel mounts root filesystem
5. System initialization continues

## Compatibility

### Infrastructure Compatibility

- **Azure**: Gen2 only (this change)
- **CloudStack**: Unchanged (continues with Gen1/MSDOS/VHD)
- **Other platforms**: Not affected

### VM Size Compatibility

Gen2 supports all modern Azure VM sizes. Some legacy VM sizes may only support Gen1:

- Check [Azure Gen2 VM support](https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2) for specific VM families
- Most commonly used VM sizes support Gen2

## Troubleshooting

### VM Fails to Boot

**Symptom**: VM doesn't start or boots to emergency mode.

**Cause**: Incorrect boot configuration.

**Resolution**:

1. Check Azure boot diagnostics
2. Verify stemcell metadata matches deployment
3. Ensure VM size supports Gen2

### Disk Performance Issues

**Symptom**: Slower than expected I/O.

**Cause**: May be using non-SCSI controller.

**Resolution**:

- Verify `disk_controller_type: scsi` in stemcell metadata
- Redeploy if needed

### Network Performance Issues

**Symptom**: Network throughput lower than expected.

**Cause**: Accelerated networking not enabled.

**Resolution**:

- Verify `accelerated_networking: true` in stemcell metadata
- Ensure VM size supports accelerated networking
- Check Azure portal for network interface settings

## FAQ

**Q: Can I use Gen1 stemcells for Noble?**  
A: No, Noble Azure stemcells are Gen2 only. Use Jammy (22.04) if Gen1 is required.

**Q: Do I need to update my deployment manifests?**  
A: Only to reference the new Noble stemcell. Cloud properties are handled automatically.

**Q: When will Secure Boot be enabled?**  
A: In a future stemcell release after thorough validation. Packages are already installed.

**Q: Does this affect existing Jammy deployments?**  
A: No, Jammy stemcells remain Gen1. Only Noble is affected.

**Q: Can I disable vTPM?**  
A: Not recommended. vTPM provides security benefits with no performance impact.

**Q: Will this affect stemcell build times?**  
A: Minimal impact. Fixed VHD conversion uses the same tooling as before.

## References

- [Azure Generation 2 VMs](https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2)
- [Azure Trusted Launch](https://learn.microsoft.com/en-us/azure/virtual-machines/trusted-launch)
- [Azure Accelerated Networking](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview)
- [UEFI Boot Process](https://wiki.ubuntu.com/EFIBootLoaders)

## Support

For issues or questions:

- Open an issue in the bosh-linux-stemcell-builder repository
- Contact the BOSH team via Cloud Foundry Slack (#bosh channel)
