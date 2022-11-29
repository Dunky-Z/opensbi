/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2019 Western Digital Corporation or its affiliates.
 *
 * Authors:
 *   Anup Patel <anup.patel@wdc.com>
 */

#include <sbi/riscv_asm.h>
#include <sbi/riscv_encoding.h>
#include <sbi/riscv_elf.h>
#include <sbi/sbi_platform.h>
#include <sbi/sbi_scratch.h>
#include <sbi/sbi_trap.h>

#define BOOT_STATUS_RELOCATE_DONE	1
#define BOOT_STATUS_BOOT_HART_DONE	2

.macro	MOV_3R __d0, __s0, __d1, __s1, __d2, __s2
	add	\__d0, \__s0, zero
	add	\__d1, \__s1, zero
	add	\__d2, \__s2, zero
.endm

.macro	MOV_5R __d0, __s0, __d1, __s1, __d2, __s2, __d3, __s3, __d4, __s4
	add	\__d0, \__s0, zero
	add	\__d1, \__s1, zero
	add	\__d2, \__s2, zero
	add	\__d3, \__s3, zero
	add	\__d4, \__s4, zero
.endm

/*
 * If __start_reg <= __check_reg and __check_reg < __end_reg then
 *   jump to __pass
 */
.macro BRANGE __start_reg, __end_reg, __check_reg, __jump_lable
	blt	\__check_reg, \__start_reg, 999f
	bge	\__check_reg, \__end_reg, 999f
	j	\__jump_lable
999:
.endm

	.section .entry, "ax", %progbits
	.align 3
	.globl _start
	.globl _start_warm
_start:
	/* Find preferred boot HART id */
    /* 先备份一下a0,a1,a2因为后续需要使用这些寄存器原有值 */
	MOV_3R	s0, a0, s1, a1, s2, a2
    /* 读取启动信息，包括boot HART id */
    /**
     * 对于fw_jump和fw_payload类型这个函数直接返回-1，不能指定Boot HART，让它们强制进入_try_lottery
     * 随机选择Boot HART。对于 fw_dynamic 类型，启动opensbi的上级程序会将参数放在struct fw_dynamic_info里，
     * 然后用a2寄存器传递给OpenSBI。fw_boot_hart函数分析见firmware/fw_dynamic.S。
     * 上级程序如何传递struct fw_dynamic_info，分析见QEMU启动OpenSBI分析。
    */
	call	fw_boot_hart
	add	a6, a0, zero
    /* 恢复a0, a1, a2的值 */
	MOV_3R	a0, s0, a1, s1, a2, s2
    /* a7 = -1 = 0xffffffff*/
	li	a7, -1
    /**
     * 除了 fw_dynamic 类型，其他类型的固件，执行时所有HART都会进入_try_lottery
     * 因为a7 一定等于 -1 一定等于 a0。
	 */
	beq	a6, a7, _try_lottery
	/**
     * 如果是 fw_dynamic 类型，那么a6寄存器在上一级会指定boot hart，并且a0是当前的hart id应该用a0
     * 经过对比，如果两者不等说明不是指定的boot hart，直接跳到等待重定位完成就行。
     * 如果是 boot hart 就继续执行
     */
	/* Jump to relocation wait loop if we are not boot hart */
	bne	a0, a6, _wait_relocate_copy_done
_try_lottery:
	/**
     * fw_dynamic 类型指定了boot hart id，只有一个hart会到这。其余类型所有hart 都会执行到这。
     * 这里的抽签机制很有意思，所有hart执行完都会把一个全局变量加1，只有第一个执行完的hart 的a6寄存器为0，
     * 所以这里就是谁先抢先执行完，谁就会进行重定向等一系列初始化操作，其余hart都等待这个hart完成初始化工作。
    */
	/* Jump to relocation wait loop if we don't get relocation lottery */
	lla	a6, _relocate_lottery   /* a6 = _relocate_lottery = 0x800004b8 */
	li	a7, 1                   /* a7 = 1 */
	amoadd.w a6, a7, (a6)
	bnez	a6, _wait_relocate_copy_done
    /**
     * 以上三行代码的过程如下：
     * int a6;
     * int a7 = 1;
     * int _relocate_lottery = 0;
     * a6 = &(_relocate_lottery);
     * a6 = *a6;
     * *a6 += a7;
     * 最终结果：
     * _relocate_lottery = 1；a7 = 1; a6 = 0; 
     * 当有其他hart再次执行时，a6每次都会自增1，这样只有第一个执行以上代码的a6才等于0。
     */
	/* Save load address */
	/**
     * t0 是 _load_start 这个符号的地址，这个地址存的是 _fw_start 的值
	 * t1 是 _fw_start 这个符号的地址，三种固件中，_fw_start 这个符号都在bin文件
	 * 的起始位置，所以，这里取_fw_start的运行时的地址，其实就是bin文件实际
	 * 被加载到的地址。
     * 保存bin文件的实际加载位置到 _load_start, qemu virt平台上的链接地址
	 * 和实际加载地址是一样的，都是内存0x80000000这个地址，但是，如果bios
	 * 是加载到其他地方，比如flash里，链接地址和实际加载位置就是不一样的。
	 * 这个时候就需要做重定向(relocate) ，把bin文件从实际加载位置拷贝到链接地址。
	 */
	lla	t0, _load_start /* t0 = _load_start = 0x800004c8 */
	lla	t1, _fw_start   /* t1 = 0x80000000 */
	/**
     * MEM[_load_start + 0] = _start 
	 * MEM[t0 + 0] = 0x80000000  
	 */
	REG_S	t1, 0(t0)

#ifdef FW_PIC
	/* 如果 load address != link address 开始重定位 */
	/* relocate the global table content */
	lla	t0, _link_start
	REG_L	t0, 0(t0)
	/* t1 shall has the address of _fw_start */
	sub	t2, t1, t0
	lla	t3, _runtime_offset
	REG_S	t2, (t3)
	lla	t0, __rel_dyn_start
	lla	t1, __rel_dyn_end
	beq	t0, t1, _relocate_done
	j	5f
2:
	REG_L	t5, -(REGBYTES*2)(t0)	/* t5 <-- relocation info:type */
	li	t3, R_RISCV_RELATIVE	/* reloc type R_RISCV_RELATIVE */
	bne	t5, t3, 3f
	REG_L	t3, -(REGBYTES*3)(t0)
	REG_L	t5, -(REGBYTES)(t0)	/* t5 <-- addend */
	add	t5, t5, t2
	add	t3, t3, t2
	REG_S	t5, 0(t3)		/* store runtime address to the GOT entry */
	j	5f

3:
	lla	t4, __dyn_sym_start

4:
	REG_L	t5, -(REGBYTES*2)(t0)	/* t5 <-- relocation info:type */
	srli	t6, t5, SYM_INDEX	/* t6 <--- sym table index */
	andi	t5, t5, 0xFF		/* t5 <--- relocation type */
	li	t3, RELOC_TYPE
	bne	t5, t3, 5f

	/* address R_RISCV_64 or R_RISCV_32 cases*/
	REG_L	t3, -(REGBYTES*3)(t0)
	li	t5, SYM_SIZE
	mul	t6, t6, t5
	add	s5, t4, t6
	REG_L	t6, -(REGBYTES)(t0)	/* t0 <-- addend */
	REG_L	t5, REGBYTES(s5)
	add	t5, t5, t6
	add	t5, t5, t2		/* t5 <-- location to fix up in RAM */
	add	t3, t3, t2		/* t3 <-- location to fix up in RAM */
	REG_S	t5, 0(t3)		/* store runtime address to the variable */

5:
    /* 循环处理.rel.dyn这个段里的信息 */
	addi	t0, t0, (REGBYTES*3)
	ble	t0, t1, 2b
	j	_relocate_done
_wait_relocate_copy_done:
	j	_wait_for_boot_hart
#else
	/* Relocate if load address != link address */
_relocate:
	lla	t0, _link_start  /* t0 = 0x800004d0 */
	REG_L	t0, 0(t0)    /* t0 = 0x80000000 */
	lla	t1, _link_end    /* t1 = 0x800004d8 */
	REG_L	t1, 0(t1)    /* t1 = 0x80201028 */
    /* 加载地址在上面已经得到，这里把加载地址取出，放到t2 */
	lla	t2, _load_start  /* t2 = 0x800004c8 */
	REG_L	t2, 0(t2)    /* t2 = 0x80000000 */
	/* if _link_start == _load_start 结束重定位 */
	beq	t0, t2, _relocate_done
	sub	t3, t1, t0       /* t3 = t1 - t0 = 201028 */
	add	t3, t3, t2       /* t3 = t3 + t2 = 0x80201028 */
	lla	t4, _relocate_done
    /* else 开始重定位 */
	sub	t4, t4, t2
	add	t4, t4, t0
    /* if load地址 < link地址 跳转到_relocate_copy_to_upper，往高地址拷贝数据 */
	blt	t2, t0, _relocate_copy_to_upper
/**
 * if load 地址 > link地址, 往低地址拷贝数据, 可以看到 t2 和 t0 是拷贝时的指针。
 * 所以，_link_end(t1)要比_load_start(t2)小，不然拷贝的时候会出现重叠的情况。
 *
 *  地 |       _link_start <--- t0
 *  址 |
 *  增 |      
 *  长 |       _link_end   <--- t1
 *  方 |
 *  向 ∨       _load_start <--- t2
 *
 * 
 *             _load_end   <--- t3
 */
_relocate_copy_to_lower:
    /* if link 地址小于等于 load地址，就搬运数据 */
	ble	t1, t2, _relocate_copy_to_lower_loop
	lla	t3, _relocate_lottery
	BRANGE	t2, t1, t3, _start_hang
	lla	t3, _boot_status
	BRANGE	t2, t1, t3, _start_hang
	lla	t3, _relocate
	lla	t5, _relocate_done
	BRANGE	t2, t1, t3, _start_hang
	BRANGE	t2, t1, t5, _start_hang
	BRANGE  t3, t5, t2, _start_hang
_relocate_copy_to_lower_loop:
    /* 每次把 t2 的数据搬到 t0 后，两个寄存器指向的地址都加上 __SIZEOF_POINTER__ 大小 */
	REG_L	t3, 0(t2)
	REG_S	t3, 0(t0)
	add	t0, t0, __SIZEOF_POINTER__
	add	t2, t2, __SIZEOF_POINTER__
    /* 直到 _link_start == _link_ends 说明数据搬完了 */
	blt	t0, t1, _relocate_copy_to_lower_loop
    /* 搬完数据就跳转到 _relocate_done */
	jr	t4

/**
 * if load 地址 < link地址, 往高地址拷贝数据, 
 *
 *  地 |      _load_start  <--- t2
 *  址 |
 *  增 |      
 *  长 |      _load_end    <--- t3
 *  方 |
 *  向 ∨      _link_start  <--- t0
 *
 * 
 *            _link_end    <--- t1
 */
_relocate_copy_to_upper:
    /* if _load_end 地址小于等于 _link_start 地址，就搬运数据 */
	ble	t3, t0, _relocate_copy_to_upper_loop
	lla	t2, _relocate_lottery
	BRANGE	t0, t3, t2, _start_hang
	lla	t2, _boot_status
	BRANGE	t0, t3, t2, _start_hang
	lla	t2, _relocate
	lla	t5, _relocate_done
	BRANGE	t0, t3, t2, _start_hang
	BRANGE	t0, t3, t5, _start_hang
	BRANGE	t2, t5, t0, _start_hang
_relocate_copy_to_upper_loop:
    /* 每次把 t3 的数据搬到 t1 后，两个寄存器指向的地址都减去 __SIZEOF_POINTER__ 大小 */
	add	t3, t3, -__SIZEOF_POINTER__
	add	t1, t1, -__SIZEOF_POINTER__
	REG_L	t2, 0(t3)
	REG_S	t2, 0(t1)
    /* 直到 _link_start == _link_ends 说明数据搬完了 */
	blt	t0, t1, _relocate_copy_to_upper_loop
    /* 搬完数据就跳转到 _relocate_done */
	jr	t4
_wait_relocate_copy_done:
	/* 等待重定位copy结束，直到_start == _link_start */
	lla	t0, _fw_start
	/* t1 = MEM[_link_start] = MEM[0x80000000] */
	lla	t1, _link_start
	REG_L	t1, 0(t1)
	beq	t0, t1, _wait_for_boot_hart
	/* t2 = _boot_status ,t3 = _wait_for_boot_hart */
	lla	t2, _boot_status
	lla	t3, _wait_for_boot_hart
	/* _wait_for_boot_hart = _wait_for_boot_hart - _start */
	/* _wait_for_boot_hart = _wait_for_boot_hart + MEM[0x80000000] */
	/* _wait_for_boot_hart = _wait_for_boot_hart - _start + MEM[0x80000000] */
	sub	t3, t3, t0
	add	t3, t3, t1
1:
	/* 等待重定位完成， 也就是 _boot_status == 1 时 */
	/* t4 = 1 */
	/* waitting for relocate copy done (_boot_status == 1) */
	li	t4, BOOT_STATUS_RELOCATE_DONE
	/* t5 = MEM[_boot_status + 0]  = 0 */
	REG_L	t5, 0(t2)
	/* 减少总线流量，以便引导hart可以更快地进行 */
	/* Reduce the bus traffic so that boot hart may proceed faster */
	nop
	nop
	nop
	/* if(1 > t5) pc += 1b */
	bgt     t4, t5, 1b
	jr	t3
#endif
_relocate_done:
/**
  * Boot HART(这里指的是抽签抽中的HART)，执行完重定向后跳转至此
  * 置 _boot_status 这个全局变量为 BOOT_STATUS_RELOCATE_DONE。
  * 其余HART一直处于等待状态，知道Boot HART完成重定向。
  */
	/*
	 * Mark relocate copy done
	 * Use _boot_status copy relative to the load address
	 */
	lla	t0, _boot_status /* t0 = 0x800004c0 */
#ifndef FW_PIC
	lla	t1, _link_start  /* t1 = 0x800004d0 */
	REG_L	t1, 0(t1)    /* t1 = 0x80000000 */
	lla	t2, _load_start  /* t2 = 0x800004c8 */
	REG_L	t2, 0(t2)    /* t2 = 0x80000000 */
	sub	t0, t0, t1       /* t0 = 0x4c0 */
	add	t0, t0, t2       /* t0 = 0x800004c0 */
#endif
	li	t1, BOOT_STATUS_RELOCATE_DONE /* t1 = 0x01 */
	REG_S	t1, 0(t0)
	fence	rw, rw
	/* 此时，我们正在从链接地址运行 */
	/* 为所有Boot HART 复位寄存器 */
	/* At this point we are running from link address */

	/* Reset all registers for boot HART */
	li	ra, 0
	call	_reset_regs
	/* 清空 BSS */
	/* Zero-out BSS */
	lla	s4, _bss_start /* s4 = 0x80013000 */
	lla	s5, _bss_end   /* s5 = 0x80016ce8 */
_bss_zero:
	REG_S	zero, (s4)             /* MEM[0x80013000] = 0 */
	add	s4, s4, __SIZEOF_POINTER__ /* s4 = 0x80013008 0x80013010 ...  */
	blt	s4, s5, _bss_zero
	/* if(s4 <s5) 循环执行，也就是将MEM[0x80013000] - MEM[0x80016ce8]这段内存全部置零 */
	/* 设置临时 trap handler 地址 */
	/* Setup temporary trap handler */
	lla	s4, _start_hang   /* s4 = 0x80000510 */
	csrw	CSR_MTVEC, s4
	/* CSR_MTVEC，它保存发生异常时处理器需要跳转到的地址， csr[0x305] = 0x80000510 */
	/* 设置临时8Kb大小栈空间 */
	/* Setup temporary stack */
	lla	s4, _fw_end                 /* s4 = 0x80017000 */
	li	s5, (SBI_SCRATCH_SIZE * 2) 	/* stack = SBI_SCRATCH_SIZE * 2 = 8Kb */
	add	sp, s4, s5 	                /* stack pointer = _fw_end + 8Kb */
	
    /* 让主固件保存信息 */
	/* Allow main firmware to save info */
	/* s0 = 0x0, s1 = 0xbf0000000, s2 = 0x102c, s3 = 0x0, s4 = 0x0 */
	MOV_5R	s0, a0, s1, a1, s2, a2, s3, a3, s4, a4
	call	fw_save_info
	MOV_5R	a0, s0, a1, s1, a2, s2, a3, s3, a4, s4

#ifdef FW_FDT_PATH
	/* Override previous arg1 */
	lla	a1, fw_fdt_bin
#endif

	/*
	 * 初始化 platform
	 * Note: 传递给固件的a0至a4寄存器是该函数的参数。
	 */
	/*
	 * Initialize platform
	 * Note: The a0 to a4 registers passed to the
	 * firmware are parameters to this function.
	 */
	MOV_5R	s0, a0, s1, a1, s2, a2, s3, a3, s4, a4
	call	fw_platform_init
	add	t0, a0, zero
	MOV_5R	a0, s0, a1, s1, a2, s2, a3, s3, a4, s4
	add	a1, t0, zero
    
	/**
     * 预加载 HART 的一些信息
     * platform是平台相关的数据结构，qemu virt 的定义在:
	 * platform/generic/platform.c, 这个是 opensbi 里针对 qemu virt平台定义
	 * 的配置。最大的核数是128，栈大小是8KB。
     */
	/* Preload HART details
	 * a4 -> platform = 0x800120e8
	 * s7 -> HART Count = 0x2
	 * s8 -> HART Stack Size = 0x2000
	 */
	lla	a4, platform
#if __riscv_xlen > 32
	lwu	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lwu	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#else
	lw	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lw	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#endif

	/* Setup scratch space for all the HARTs*/
	lla	tp, _fw_end
    /* 算出全部核需要的栈内存大小 */
	mul	a5, s7, s8
    /* tp,t3都指向全部栈内存的起始基地址 */
	add	tp, tp, a5
	/* Keep a copy of tp */
	add	t3, tp, zero
	/* Counter */
	li	t2, 1
	/* hartid 0 is mandated by ISA */
	li	t1, 0
_scratch_init:
	/*
	 * The following registers hold values that are computed before
	 * entering this block, and should remain unchanged.
	 *
	 * t3 -> the firmware end address
	 * s7 -> HART count
	 * s8 -> HART stack size
	 */
    /**
     * 
                  _fw_star ---->+---------+       +----------->+---------+
                                |         |       |            |         |
                                |         |       |            |         |
                                |         |       |            |         |
                                |         |       |            |         |
                                |         |       |            |  stack  |        |
                                |         |       |            |         |        |
      t3-->  tp--> _fw_end ---->+---------+       |            |         |        |
                                |  8K     |       |            |         |        |
                                | HART N  |       |            |         |        |
                                +---------+       |            |         |        |
                                |         |       |            +---------+        | 地址增长方向
                                |         |       |            |         |        |
                                | ....... |       |            |         |        |
                                |         |       |            |         |        |
                                +---------+       |            |         |        |
                                |  8K     |       |            |   4K    |        |
                                | HART 2  |       |            | scratch |        |
                                +---------+       |            |         |        |
                                |  8K     |       |            |         |        v
                                | HART 1  |       |            |         |
                                +---------+-------+            |         |
                                |  8K     |                    |         |
                                | HART 0  |                    |         |
                                +---------+------------------->+---------+
     */
	add	tp, t3, zero
    /**
     * t1是首次是0，所以，首次计算a5是0，这个t1是hart的编号，s8是每个核的栈大小，
	 * 所以，a5是每个hart的栈的偏移。
     */
	mul	a5, s8, t1
    /**
     * 
                  _fw_star ---->+---------+       +----------->+---------+
                                |         |       |            |         |
                                |         |       |            |         |
                                |         |       |            |         |
                                |         |       |            |         |
                                |         |       |            |  stack  |        |
                                |         |       |            |         |        |
                   _fw_end ---->+---------+       |            |         |        |
                                |  8K     |       |            |         |        |
                                | HART N  |       |            |         |        |
                                +---------+       |            |         |        |
                                |         |       |            +---------+        | 地址增长方向
                                |         |       |            |         |        |
                                | ....... |       |            |         |        |
                                |         |       |            |         |        |
                                +---------+       |            |         |        |
                                |  8K     |       |            |   4K    |        |
                                | HART 2  |       |            | scratch |        |
                                +---------+       |            |         |        |
                                |  8K     |       |            |         |        v
                                | HART 1  |       |            |         |
                                +---------+-------+            |         |
                                |  8K     |                    |         |
                                | HART 0  |                    |         |
                                +---------+------------------->+---------+ <-- tp
     */
    /**
     * 可以看到每个hart的栈是全部栈内存的基地址开始，随hart id增加，依次
	 * 向小地址分配，每个核的scratch内存是4KB，是从栈的中间开始的。
     */
	sub	tp, tp, a5
 	li	a5, SBI_SCRATCH_SIZE
    /**
    * 
                  _fw_star ---->+---------+       +----------->+---------+
                                |         |       |            |         |
                                |         |       |            |         |
                                |         |       |            |         |
                                |         |       |            |         |
                                |         |       |            |  stack  |        |
                                |         |       |            |         |        |
                   _fw_end ---->+---------+       |            |         |        |
                                |  8K     |       |            |         |        |
                                | HART N  |       |            |         |        |
                                +---------+       |            |         |        |
                                |         |       |            +---------+ <-- tp | 地址增长方向
                                |         |       |            |         |        |
                                | ....... |       |            |         |        |
                                |         |       |            |         |        |
                                +---------+       |            |         |        |
                                |  8K     |       |            |   4K    |        |
                                | HART 2  |       |            | scratch |        |
                                +---------+       |            |         |        |
                                |  8K     |       |            |         |        v
                                | HART 1  |       |            |         |
                                +---------+-------+            |         |
                                |  8K     |                    |         |
                                | HART 0  |                    |         |
                                +---------+------------------->+---------+ <-- t3
    */
	sub	tp, tp, a5
	/* 为所有HART设置scratch空间 */
	/* Initialize scratch space */
	/* Store fw_start and fw_size in scratch space */
    /* 初始化 scratch 空间 */
	/* 保存 fw_start 和 fw_size */
	lla	a4, _fw_start
	sub	a5, t3, a4
	REG_S	a4, SBI_SCRATCH_FW_START_OFFSET(tp)
	REG_S	a5, SBI_SCRATCH_FW_SIZE_OFFSET(tp)
	/* Store next arg1 in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
    /**
     * 从opensbi的上一个bootloader拿opensbi启动下一个系统(一般是内核)。
     * 可以看到，三种fw的函数个不相同，fw_dynamic对上和对下都有固定的参数传递数据结构；
     * fw_jump 和 fw_payload 的处理一样，可以是编译配置的参数，也可以是从a1传递的参数。
     * a0是如下函数的返回值。
     * 可以看到 _dynamic_next_arg1 相关的内存和 scratch 内存是两个不同的概念。
     * 下面就是填scratch的各个域段。
     */
	call	fw_next_arg1
	REG_S	a0, SBI_SCRATCH_NEXT_ARG1_OFFSET(tp)
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Store next address in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_addr
	REG_S	a0, SBI_SCRATCH_NEXT_ADDR_OFFSET(tp)
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Store next mode in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_mode
	REG_S	a0, SBI_SCRATCH_NEXT_MODE_OFFSET(tp)
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Store warm_boot address in scratch space */
	lla	a4, _start_warm
	REG_S	a4, SBI_SCRATCH_WARMBOOT_ADDR_OFFSET(tp)
	/* Store platform address in scratch space */
	lla	a4, platform
	REG_S	a4, SBI_SCRATCH_PLATFORM_ADDR_OFFSET(tp)
	/* Store hartid-to-scratch function address in scratch space */
	lla	a4, _hartid_to_scratch
	REG_S	a4, SBI_SCRATCH_HARTID_TO_SCRATCH_OFFSET(tp)
	/* Store trap-exit function address in scratch space */
	lla	a4, _trap_exit
	REG_S	a4, SBI_SCRATCH_TRAP_EXIT_OFFSET(tp)
	/* Clear tmp0 in scratch space */
	REG_S	zero, SBI_SCRATCH_TMP0_OFFSET(tp)
	/* Store firmware options in scratch space */
	MOV_3R	s0, a0, s1, a1, s2, a2
#ifdef FW_OPTIONS
	li	a0, FW_OPTIONS
#else
	call	fw_options
#endif
	REG_S	a0, SBI_SCRATCH_OPTIONS_OFFSET(tp)
	MOV_3R	a0, s0, a1, s1, a2, s2
	/* Move to next scratch space */
    /* t1 就是HART index，t2 = 1，每初始化完一个HART scratch空间后加1
     * 开始初始化下一个HART scratch空间
     */
	add	t1, t1, t2
    /* s7 表示 HART 的个数，如果小于 s7 说明还有 HART 的 scratch 没初始化 */
	blt	t1, s7, _scratch_init

	/*
	 * Relocate Flatened Device Tree (FDT)
	 * source FDT address = previous arg1
	 * destination FDT address = next arg1
	 *
	 * Note: We will preserve a0 and a1 passed by
	 * previous booting stage.
	 */
	beqz	a1, _fdt_reloc_done
	/* Mask values in a4 */
	li	a4, 0xff
	/* t1 = destination FDT start address */
	MOV_3R	s0, a0, s1, a1, s2, a2
	call	fw_next_arg1
	add	t1, a0, zero
	MOV_3R	a0, s0, a1, s1, a2, s2
	beqz	t1, _fdt_reloc_done
	beq	t1, a1, _fdt_reloc_done
	/* t0 = source FDT start address */
	add	t0, a1, zero
	/* t2 = source FDT size in big-endian */
#if __riscv_xlen == 64
	lwu	t2, 4(t0)
#else
	lw	t2, 4(t0)
#endif
	/* t3 = bit[15:8] of FDT size */
	add	t3, t2, zero
	srli	t3, t3, 16
	and	t3, t3, a4
	slli	t3, t3, 8
	/* t4 = bit[23:16] of FDT size */
	add	t4, t2, zero
	srli	t4, t4, 8
	and	t4, t4, a4
	slli	t4, t4, 16
	/* t5 = bit[31:24] of FDT size */
	add	t5, t2, zero
	and	t5, t5, a4
	slli	t5, t5, 24
	/* t2 = bit[7:0] of FDT size */
	srli	t2, t2, 24
	and	t2, t2, a4
	/* t2 = FDT size in little-endian */
	or	t2, t2, t3
	or	t2, t2, t4
	or	t2, t2, t5
	/* t2 = destination FDT end address */
	add	t2, t1, t2
	/* FDT copy loop */
	ble	t2, t1, _fdt_reloc_done
_fdt_reloc_again:
	REG_L	t3, 0(t0)
	REG_S	t3, 0(t1)
	add	t0, t0, __SIZEOF_POINTER__
	add	t1, t1, __SIZEOF_POINTER__
	blt	t1, t2, _fdt_reloc_again
_fdt_reloc_done:

	/* mark boot hart done */
	li	t0, BOOT_STATUS_BOOT_HART_DONE
	lla	t1, _boot_status
	REG_S	t0, 0(t1)
	fence	rw, rw
	j	_start_warm

	/* waiting for boot hart to be done (_boot_status == 2) */
_wait_for_boot_hart:
	li	t0, BOOT_STATUS_BOOT_HART_DONE
	lla	t1, _boot_status
	REG_L	t1, 0(t1)
	/* Reduce the bus traffic so that boot hart may proceed faster */
	nop
	nop
	nop
	bne	t0, t1, _wait_for_boot_hart

_start_warm:
	/* 禁用并清除所有中断 */
	/* Reset all registers for non-boot HARTs */
	li	ra, 0
	call	_reset_regs

	/* Disable and clear all interrupts */
	csrw	CSR_MIE, zero /* xIE, 打开（1）或者关闭（0）M/S/U 模式下对应的 External/Timer/Software 中断，此处清除M模式下所有中断 */
	csrw	CSR_MIP, zero /* xIP, 获取当前 M/S/U 模式下对应的 External/Timer/Software 中断是否发生，同上 */

	/* 查找 HART 数量和 HART 堆栈大小 */
	/* Find HART count and HART stack size */
	lla	a4, platform
#if __riscv_xlen == 64
	lwu	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lwu	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#else
	lw	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lw	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#endif
	REG_L	s9, SBI_PLATFORM_HART_INDEX2ID_OFFSET(a4)
	/* 查询 HART id */
	/* Find HART id */
	csrr	s6, CSR_MHARTID
	/* 查询 HART index 如果s9 = 0，跳转到标号3处执行*/
	/* Find HART index */
	beqz	s9, 3f
	li	a4, 0
1:
#if __riscv_xlen == 64
	lwu	a5, (s9)
#else
	lw	a5, (s9)
#endif
	beq	a5, s6, 2f
	add	s9, s9, 4
	add	a4, a4, 1
	blt	a4, s7, 1b
	li	a4, -1
2:	add	s6, a4, zero
3:	bge	s6, s7, _start_hang

	/* Find the scratch space based on HART index */
	lla	tp, _fw_end
	mul	a5, s7, s8
	add	tp, tp, a5
	mul	a5, s8, s6
	sub	tp, tp, a5
	li	a5, SBI_SCRATCH_SIZE
	sub	tp, tp, a5

	/* update the mscratch */
	csrw	CSR_MSCRATCH, tp

	/* Setup stack */
	add	sp, tp, zero

	/* Setup trap handler */
	lla	a4, _trap_handler
#if __riscv_xlen == 32
	csrr	a5, CSR_MISA
	srli	a5, a5, ('H' - 'A')
	andi	a5, a5, 0x1
	beq	a5, zero, _skip_trap_handler_rv32_hyp
	lla	a4, _trap_handler_rv32_hyp
_skip_trap_handler_rv32_hyp:
#endif
	csrw	CSR_MTVEC, a4  /* CSR_MTVEC = _trap_handler = 0x80000520 */

#if __riscv_xlen == 32
	/* Override trap exit for H-extension */
	csrr	a5, CSR_MISA
	srli	a5, a5, ('H' - 'A')
	andi	a5, a5, 0x1
	beq	a5, zero, _skip_trap_exit_rv32_hyp
	lla	a4, _trap_exit_rv32_hyp
	csrr	a5, CSR_MSCRATCH
	REG_S	a4, SBI_SCRATCH_TRAP_EXIT_OFFSET(a5)
_skip_trap_exit_rv32_hyp:
#endif
	/* 初始化SBI */
	/* Initialize SBI runtime */
	csrr	a0, CSR_MSCRATCH /* a0 = MSCRATCH */
	call	sbi_init         /* 调用sbi_init函数，a0即函数的参数，也就是MSCRATCH执行的地址 */

	/* We don't expect to reach here hence just hang */
	j	_start_hang

	.data
	.align 3
#ifdef FW_PIC
_runtime_offset:
	RISCV_PTR	0
#endif
_relocate_lottery:
	RISCV_PTR	0
_boot_status:
	RISCV_PTR	0
_load_start:
	RISCV_PTR	_fw_start
_link_start:
	RISCV_PTR	FW_TEXT_START
_link_end:
	RISCV_PTR	_fw_reloc_end

	.section .entry, "ax", %progbits
	.align 3
	.globl _hartid_to_scratch
_hartid_to_scratch:
	/*
	 * a0 -> HART ID (passed by caller)
	 * a1 -> HART Index (passed by caller)
	 * t0 -> HART Stack Size
	 * t1 -> HART Stack End
	 * t2 -> Temporary
	 */
	lla	t2, platform
#if __riscv_xlen == 64
	lwu	t0, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(t2)
	lwu	t2, SBI_PLATFORM_HART_COUNT_OFFSET(t2)
#else
	lw	t0, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(t2)
	lw	t2, SBI_PLATFORM_HART_COUNT_OFFSET(t2)
#endif
	sub	t2, t2, a1
	mul	t2, t2, t0
	lla	t1, _fw_end
	add	t1, t1, t2
	li	t2, SBI_SCRATCH_SIZE
	sub	a0, t1, t2
	ret

	.section .entry, "ax", %progbits
	.align 3
	.globl _start_hang
_start_hang:
	wfi
	j	_start_hang

	.section .entry, "ax", %progbits
	.align 3
	.weak fw_platform_init
fw_platform_init:
	add	a0, a1, zero
	ret

	/* Map implicit memcpy() added by compiler to sbi_memcpy() */
	.section .text
	.align 3
	.globl memcpy
memcpy:
	tail	sbi_memcpy

	/* Map implicit memset() added by compiler to sbi_memset() */
	.section .text
	.align 3
	.globl memset
memset:
	tail	sbi_memset

	/* Map implicit memmove() added by compiler to sbi_memmove() */
	.section .text
	.align 3
	.globl memmove
memmove:
	tail	sbi_memmove

	/* Map implicit memcmp() added by compiler to sbi_memcmp() */
	.section .text
	.align 3
	.globl memcmp
memcmp:
	tail	sbi_memcmp

.macro	TRAP_SAVE_AND_SETUP_SP_T0
	/* Swap TP and MSCRATCH */
	csrrw	tp, CSR_MSCRATCH, tp

	/* Save T0 in scratch space */
	REG_S	t0, SBI_SCRATCH_TMP0_OFFSET(tp)

	/*
	 * Set T0 to appropriate exception stack
	 *
	 * Came_From_M_Mode = ((MSTATUS.MPP < PRV_M) ? 1 : 0) - 1;
	 * Exception_Stack = TP ^ (Came_From_M_Mode & (SP ^ TP))
	 *
	 * Came_From_M_Mode = 0    ==>    Exception_Stack = TP
	 * Came_From_M_Mode = -1   ==>    Exception_Stack = SP
	 */
	csrr	t0, CSR_MSTATUS
	srl	t0, t0, MSTATUS_MPP_SHIFT
	and	t0, t0, PRV_M
	slti	t0, t0, PRV_M
	add	t0, t0, -1
	xor	sp, sp, tp
	and	t0, t0, sp
	xor	sp, sp, tp
	xor	t0, tp, t0

	/* Save original SP on exception stack */
	REG_S	sp, (SBI_TRAP_REGS_OFFSET(sp) - SBI_TRAP_REGS_SIZE)(t0)

	/* Set SP to exception stack and make room for trap registers */
	add	sp, t0, -(SBI_TRAP_REGS_SIZE)

	/* Restore T0 from scratch space */
	REG_L	t0, SBI_SCRATCH_TMP0_OFFSET(tp)

	/* Save T0 on stack */
	REG_S	t0, SBI_TRAP_REGS_OFFSET(t0)(sp)

	/* Swap TP and MSCRATCH */
	csrrw	tp, CSR_MSCRATCH, tp
.endm

.macro	TRAP_SAVE_MEPC_MSTATUS have_mstatush
	/* Save MEPC and MSTATUS CSRs */
	csrr	t0, CSR_MEPC
	REG_S	t0, SBI_TRAP_REGS_OFFSET(mepc)(sp)
	csrr	t0, CSR_MSTATUS
	REG_S	t0, SBI_TRAP_REGS_OFFSET(mstatus)(sp)
	.if \have_mstatush
	csrr	t0, CSR_MSTATUSH
	REG_S	t0, SBI_TRAP_REGS_OFFSET(mstatusH)(sp)
	.else
	REG_S	zero, SBI_TRAP_REGS_OFFSET(mstatusH)(sp)
	.endif
.endm

.macro	TRAP_SAVE_GENERAL_REGS_EXCEPT_SP_T0
	/* Save all general regisers except SP and T0 */
	REG_S	zero, SBI_TRAP_REGS_OFFSET(zero)(sp)
	REG_S	ra, SBI_TRAP_REGS_OFFSET(ra)(sp)
	REG_S	gp, SBI_TRAP_REGS_OFFSET(gp)(sp)
	REG_S	tp, SBI_TRAP_REGS_OFFSET(tp)(sp)
	REG_S	t1, SBI_TRAP_REGS_OFFSET(t1)(sp)
	REG_S	t2, SBI_TRAP_REGS_OFFSET(t2)(sp)
	REG_S	s0, SBI_TRAP_REGS_OFFSET(s0)(sp)
	REG_S	s1, SBI_TRAP_REGS_OFFSET(s1)(sp)
	REG_S	a0, SBI_TRAP_REGS_OFFSET(a0)(sp)
	REG_S	a1, SBI_TRAP_REGS_OFFSET(a1)(sp)
	REG_S	a2, SBI_TRAP_REGS_OFFSET(a2)(sp)
	REG_S	a3, SBI_TRAP_REGS_OFFSET(a3)(sp)
	REG_S	a4, SBI_TRAP_REGS_OFFSET(a4)(sp)
	REG_S	a5, SBI_TRAP_REGS_OFFSET(a5)(sp)
	REG_S	a6, SBI_TRAP_REGS_OFFSET(a6)(sp)
	REG_S	a7, SBI_TRAP_REGS_OFFSET(a7)(sp)
	REG_S	s2, SBI_TRAP_REGS_OFFSET(s2)(sp)
	REG_S	s3, SBI_TRAP_REGS_OFFSET(s3)(sp)
	REG_S	s4, SBI_TRAP_REGS_OFFSET(s4)(sp)
	REG_S	s5, SBI_TRAP_REGS_OFFSET(s5)(sp)
	REG_S	s6, SBI_TRAP_REGS_OFFSET(s6)(sp)
	REG_S	s7, SBI_TRAP_REGS_OFFSET(s7)(sp)
	REG_S	s8, SBI_TRAP_REGS_OFFSET(s8)(sp)
	REG_S	s9, SBI_TRAP_REGS_OFFSET(s9)(sp)
	REG_S	s10, SBI_TRAP_REGS_OFFSET(s10)(sp)
	REG_S	s11, SBI_TRAP_REGS_OFFSET(s11)(sp)
	REG_S	t3, SBI_TRAP_REGS_OFFSET(t3)(sp)
	REG_S	t4, SBI_TRAP_REGS_OFFSET(t4)(sp)
	REG_S	t5, SBI_TRAP_REGS_OFFSET(t5)(sp)
	REG_S	t6, SBI_TRAP_REGS_OFFSET(t6)(sp)
.endm

.macro	TRAP_CALL_C_ROUTINE
	/* Call C routine */
	add	a0, sp, zero
	call	sbi_trap_handler
.endm

.macro	TRAP_RESTORE_GENERAL_REGS_EXCEPT_A0_T0
	/* Restore all general regisers except A0 and T0 */
	REG_L	ra, SBI_TRAP_REGS_OFFSET(ra)(a0)
	REG_L	sp, SBI_TRAP_REGS_OFFSET(sp)(a0)
	REG_L	gp, SBI_TRAP_REGS_OFFSET(gp)(a0)
	REG_L	tp, SBI_TRAP_REGS_OFFSET(tp)(a0)
	REG_L	t1, SBI_TRAP_REGS_OFFSET(t1)(a0)
	REG_L	t2, SBI_TRAP_REGS_OFFSET(t2)(a0)
	REG_L	s0, SBI_TRAP_REGS_OFFSET(s0)(a0)
	REG_L	s1, SBI_TRAP_REGS_OFFSET(s1)(a0)
	REG_L	a1, SBI_TRAP_REGS_OFFSET(a1)(a0)
	REG_L	a2, SBI_TRAP_REGS_OFFSET(a2)(a0)
	REG_L	a3, SBI_TRAP_REGS_OFFSET(a3)(a0)
	REG_L	a4, SBI_TRAP_REGS_OFFSET(a4)(a0)
	REG_L	a5, SBI_TRAP_REGS_OFFSET(a5)(a0)
	REG_L	a6, SBI_TRAP_REGS_OFFSET(a6)(a0)
	REG_L	a7, SBI_TRAP_REGS_OFFSET(a7)(a0)
	REG_L	s2, SBI_TRAP_REGS_OFFSET(s2)(a0)
	REG_L	s3, SBI_TRAP_REGS_OFFSET(s3)(a0)
	REG_L	s4, SBI_TRAP_REGS_OFFSET(s4)(a0)
	REG_L	s5, SBI_TRAP_REGS_OFFSET(s5)(a0)
	REG_L	s6, SBI_TRAP_REGS_OFFSET(s6)(a0)
	REG_L	s7, SBI_TRAP_REGS_OFFSET(s7)(a0)
	REG_L	s8, SBI_TRAP_REGS_OFFSET(s8)(a0)
	REG_L	s9, SBI_TRAP_REGS_OFFSET(s9)(a0)
	REG_L	s10, SBI_TRAP_REGS_OFFSET(s10)(a0)
	REG_L	s11, SBI_TRAP_REGS_OFFSET(s11)(a0)
	REG_L	t3, SBI_TRAP_REGS_OFFSET(t3)(a0)
	REG_L	t4, SBI_TRAP_REGS_OFFSET(t4)(a0)
	REG_L	t5, SBI_TRAP_REGS_OFFSET(t5)(a0)
	REG_L	t6, SBI_TRAP_REGS_OFFSET(t6)(a0)
.endm

.macro	TRAP_RESTORE_MEPC_MSTATUS have_mstatush
	/* Restore MEPC and MSTATUS CSRs */
	REG_L	t0, SBI_TRAP_REGS_OFFSET(mepc)(a0)
	csrw	CSR_MEPC, t0
	REG_L	t0, SBI_TRAP_REGS_OFFSET(mstatus)(a0)
	csrw	CSR_MSTATUS, t0
	.if \have_mstatush
	REG_L	t0, SBI_TRAP_REGS_OFFSET(mstatusH)(a0)
	csrw	CSR_MSTATUSH, t0
	.endif
.endm

.macro TRAP_RESTORE_A0_T0
	/* Restore T0 */
	REG_L	t0, SBI_TRAP_REGS_OFFSET(t0)(a0)

	/* Restore A0 */
	REG_L	a0, SBI_TRAP_REGS_OFFSET(a0)(a0)
.endm

	.section .entry, "ax", %progbits
	.align 3
	.globl _trap_handler
	.globl _trap_exit
_trap_handler:
	TRAP_SAVE_AND_SETUP_SP_T0

	TRAP_SAVE_MEPC_MSTATUS 0

	TRAP_SAVE_GENERAL_REGS_EXCEPT_SP_T0

	TRAP_CALL_C_ROUTINE

_trap_exit:
	TRAP_RESTORE_GENERAL_REGS_EXCEPT_A0_T0

	TRAP_RESTORE_MEPC_MSTATUS 0

	TRAP_RESTORE_A0_T0

	mret

#if __riscv_xlen == 32
	.section .entry, "ax", %progbits
	.align 3
	.globl _trap_handler_rv32_hyp
	.globl _trap_exit_rv32_hyp
_trap_handler_rv32_hyp:
	TRAP_SAVE_AND_SETUP_SP_T0

	TRAP_SAVE_MEPC_MSTATUS 1

	TRAP_SAVE_GENERAL_REGS_EXCEPT_SP_T0

	TRAP_CALL_C_ROUTINE

_trap_exit_rv32_hyp:
	TRAP_RESTORE_GENERAL_REGS_EXCEPT_A0_T0

	TRAP_RESTORE_MEPC_MSTATUS 1

	TRAP_RESTORE_A0_T0

	mret
#endif

	.section .entry, "ax", %progbits
	.align 3
	.globl _reset_regs
_reset_regs:

	/* flush the instruction cache */
	fence.i
	/* Reset all registers except ra, a0, a1 and a2 */
	li sp, 0
	li gp, 0
	li tp, 0
	li t0, 0
	li t1, 0
	li t2, 0
	li s0, 0
	li s1, 0
	li a3, 0
	li a4, 0
	li a5, 0
	li a6, 0
	li a7, 0
	li s2, 0
	li s3, 0
	li s4, 0
	li s5, 0
	li s6, 0
	li s7, 0
	li s8, 0
	li s9, 0
	li s10, 0
	li s11, 0
	li t3, 0
	li t4, 0
	li t5, 0
	li t6, 0
    /* CSR_MSCRATCH，Machine 模式下专用寄存器，我们可以自己定义其用法，譬如用该寄存器保存当前在 hart 上运行的 task 的上下文的地址 */
	csrw CSR_MSCRATCH, 0

	ret

#ifdef FW_FDT_PATH
	.section .rodata
	.align 4
	.globl fw_fdt_bin
fw_fdt_bin:
	.incbin FW_FDT_PATH
#ifdef FW_FDT_PADDING
	.fill FW_FDT_PADDING, 1, 0
#endif
#endif
