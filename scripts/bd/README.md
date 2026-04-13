# Block Design Source of Truth

Vivado block designs are treated as generated project content. The Git-tracked
source of truth is the exported BD Tcl in this directory.

## Recommended workflow

1. Edit the BD in Vivado GUI.
2. Export the BD Tcl after each meaningful BD change:

```tcl
write_bd_tcl -force scripts/bd/zynq_dma_bd.tcl
```

3. Commit the updated Tcl together with any RTL / XDC changes.

## Rebuild behavior

`scripts/rebuild_project.tcl` will automatically:

1. create a clean Vivado project under `build/vivado/`
2. add RTL / constraints / simulation sources
3. source every `*.tcl` file in `scripts/bd/`
4. regenerate the BD output products
5. create and add the HDL wrapper
6. use the wrapper as synthesis top

## What not to commit

Do not commit Vivado-generated project directories such as:

- `*.cache/`
- `*.gen/`
- `*.hw/`
- `*.ip_user_files/`
- `*.runs/`
- `*.sim/`
- `*.srcs/`
- `.Xil/`
- `*.xpr`
