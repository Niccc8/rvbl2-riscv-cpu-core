	.file	"hal.c"
	.option nopic
	.option norelax
	.attribute arch, "rv32i2p1_zmmul1p0"
	.attribute unaligned_access, 0
	.attribute stack_align, 16
	.text
	.align	2
	.globl	uart_putc
	.type	uart_putc, @function
uart_putc:
	li	a4,-251658240
	addi	a4,a4,8
.L2:
	lw	a5,0(a4)
	andi	a5,a5,4
	beq	a5,zero,.L2
	li	a5,-251658240
	sw	a0,0(a5)
	li	a5,3
	sw	a5,0(a4)
	ret
	.size	uart_putc, .-uart_putc
	.align	2
	.globl	uart_try_getc
	.type	uart_try_getc, @function
uart_try_getc:
	li	a5,-251658240
	lw	a4,8(a5)
	mv	a3,a0
	addi	a5,a5,8
	andi	a4,a4,2
	beq	a4,zero,.L8
	li	a4,-251658240
	lw	a2,4(a4)
	li	a0,1
	sb	a2,0(a3)
	sw	zero,0(a5)
	ret
.L8:
	li	a0,0
	ret
	.size	uart_try_getc, .-uart_try_getc
	.align	2
	.globl	uart_getc
	.type	uart_getc, @function
uart_getc:
	li	a4,-251658240
	addi	a4,a4,8
.L10:
	lw	a5,0(a4)
	andi	a5,a5,2
	beq	a5,zero,.L10
	li	a5,-251658240
	lw	a0,4(a5)
	sw	zero,0(a4)
	andi	a0,a0,0xff
	ret
	.size	uart_getc, .-uart_getc
	.align	2
	.globl	uart_puts
	.type	uart_puts, @function
uart_puts:
	lbu	a3,0(a0)
	beq	a3,zero,.L13
	li	a4,-251658240
	li	a1,-251658240
	addi	a4,a4,8
	li	a2,3
.L16:
	addi	a0,a0,1
.L15:
	lw	a5,0(a4)
	andi	a5,a5,4
	beq	a5,zero,.L15
	sw	a3,0(a1)
	sw	a2,0(a4)
	lbu	a3,0(a0)
	bne	a3,zero,.L16
.L13:
	ret
	.size	uart_puts, .-uart_puts
	.section	.rodata.str1.4,"aMS",@progbits,1
	.align	2
.LC0:
	.string	"0123456789abcdef"
	.text
	.align	2
	.globl	uart_put_hex32
	.type	uart_put_hex32, @function
uart_put_hex32:
	li	a4,-251658240
	lui	a1,%hi(.LC0)
	li	a3,28
	addi	a1,a1,%lo(.LC0)
	li	t1,-251658240
	addi	a4,a4,8
	li	a7,3
	li	a6,-4
.L25:
	srl	a5,a0,a3
	andi	a5,a5,15
	add	a5,a1,a5
	lbu	a2,0(a5)
.L24:
	lw	a5,0(a4)
	andi	a5,a5,4
	beq	a5,zero,.L24
	sw	a2,0(t1)
	sw	a7,0(a4)
	addi	a3,a3,-4
	bne	a3,a6,.L25
	ret
	.size	uart_put_hex32, .-uart_put_hex32
	.globl	__umodsi3
	.globl	__udivsi3
	.align	2
	.globl	uart_put_dec
	.type	uart_put_dec, @function
uart_put_dec:
	addi	sp,sp,-48
	sw	s0,40(sp)
	sw	s2,32(sp)
	sw	s3,28(sp)
	sw	s5,20(sp)
	sw	ra,44(sp)
	sw	s1,36(sp)
	sw	s4,24(sp)
	mv	s0,a0
	li	s2,0
	addi	s3,sp,4
	li	s5,9
.L30:
	li	a1,10
	mv	a0,s0
	call	__umodsi3
	addi	s2,s2,1
	addi	a5,a0,48
	add	s1,s3,s2
	mv	a0,s0
	li	a1,10
	sb	a5,-1(s1)
	mv	s4,s0
	call	__udivsi3
	mv	s0,a0
	bgtu	s4,s5,.L30
	li	a4,-251658240
	mv	a3,s1
	li	a0,-251658240
	addi	a4,a4,8
	li	a1,3
.L32:
	lbu	a2,-1(a3)
.L31:
	lw	a5,0(a4)
	andi	a5,a5,4
	beq	a5,zero,.L31
	sw	a2,0(a0)
	sw	a1,0(a4)
	addi	a3,a3,-1
	bne	s3,a3,.L32
	lw	ra,44(sp)
	lw	s0,40(sp)
	lw	s1,36(sp)
	lw	s2,32(sp)
	lw	s3,28(sp)
	lw	s4,24(sp)
	lw	s5,20(sp)
	addi	sp,sp,48
	jr	ra
	.size	uart_put_dec, .-uart_put_dec
	.align	2
	.globl	uart_write_u16
	.type	uart_write_u16, @function
uart_write_u16:
	li	a3,-251658240
	andi	a4,a0,0xff
	addi	a3,a3,8
.L39:
	lw	a5,0(a3)
	andi	a5,a5,4
	beq	a5,zero,.L39
	li	a5,-251658240
	sw	a4,0(a5)
	li	a4,-251658240
	li	a5,3
	sw	a5,0(a3)
	srli	a0,a0,8
	addi	a4,a4,8
.L40:
	lw	a5,0(a4)
	andi	a5,a5,4
	beq	a5,zero,.L40
	li	a5,-251658240
	sw	a0,0(a5)
	li	a5,3
	sw	a5,0(a4)
	ret
	.size	uart_write_u16, .-uart_write_u16
	.align	2
	.globl	uart_write_u32
	.type	uart_write_u32, @function
uart_write_u32:
	li	a4,-251658240
	li	a3,0
	li	a7,-251658240
	addi	a4,a4,8
	li	a6,3
	li	a1,32
.L47:
	srl	a2,a0,a3
.L46:
	lw	a5,0(a4)
	andi	a5,a5,4
	beq	a5,zero,.L46
	andi	a5,a2,255
	sw	a5,0(a7)
	sw	a6,0(a4)
	addi	a3,a3,8
	bne	a3,a1,.L47
	ret
	.size	uart_write_u32, .-uart_write_u32
	.align	2
	.globl	uart_read_u16
	.type	uart_read_u16, @function
uart_read_u16:
	li	a2,-251658240
	addi	a2,a2,8
.L52:
	lw	a5,0(a2)
	andi	a5,a5,2
	beq	a5,zero,.L52
	li	a5,-251658240
	lw	a3,4(a5)
	li	a4,-251658240
	sw	zero,0(a2)
	andi	a3,a3,0xff
	addi	a4,a4,8
.L53:
	lw	a5,0(a4)
	andi	a5,a5,2
	beq	a5,zero,.L53
	li	a5,-251658240
	lw	a0,4(a5)
	sw	zero,0(a4)
	andi	a0,a0,0xff
	slli	a0,a0,8
	or	a0,a0,a3
	slli	a0,a0,16
	srli	a0,a0,16
	ret
	.size	uart_read_u16, .-uart_read_u16
	.align	2
	.globl	uart_read_u32
	.type	uart_read_u32, @function
uart_read_u32:
	li	a3,-251658240
	li	a2,-251658240
	li	a4,0
	li	a0,0
	addi	a3,a3,8
	addi	a2,a2,4
	li	a1,32
.L59:
	lw	a5,0(a3)
	andi	a5,a5,2
	beq	a5,zero,.L59
	lw	a5,0(a2)
	sw	zero,0(a3)
	andi	a5,a5,255
	sll	a5,a5,a4
	addi	a4,a4,8
	or	a0,a0,a5
	bne	a4,a1,.L59
	ret
	.size	uart_read_u32, .-uart_read_u32
	.align	2
	.globl	crc16_ccitt
	.type	crc16_ccitt, @function
crc16_ccitt:
	mv	a5,a0
	beq	a2,zero,.L65
	add	a2,a1,a2
.L66:
	addi	a1,a1,1
	lbu	a4,-1(a1)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a5, a4, a5
# 0 "" 2
 #NO_APP
	bne	a1,a2,.L66
	slli	a0,a5,16
	srli	a0,a0,16
.L65:
	ret
	.size	crc16_ccitt, .-crc16_ccitt
	.align	2
	.globl	chaskey12_round
	.type	chaskey12_round, @function
chaskey12_round:
	lw	a3,4(a0)
	lw	a5,12(a0)
	lw	a7,8(a0)
	lw	t1,0(a0)
	srli	a6,a3,27
	srli	a1,a5,24
	slli	a4,a3,5
	slli	a2,a5,8
	add	a3,a3,t1
	add	a5,a5,a7
	or	a4,a4,a6
	or	a2,a2,a1
	xor	a2,a2,a5
	xor	a4,a4,a3
	slli	a1,a3,16
	srli	a3,a3,16
	add	a5,a4,a5
	or	a3,a1,a3
	slli	a6,a2,13
	slli	a1,a4,7
	srli	a7,a2,19
	srli	a4,a4,25
	add	a3,a3,a2
	or	a4,a1,a4
	or	a2,a6,a7
	slli	a1,a5,16
	srli	a6,a5,16
	xor	a2,a2,a3
	xor	a5,a4,a5
	or	a4,a1,a6
	sw	a3,0(a0)
	sw	a2,12(a0)
	sw	a5,4(a0)
	sw	a4,8(a0)
	ret
	.size	chaskey12_round, .-chaskey12_round
	.align	2
	.globl	chaskey12_subkeys
	.type	chaskey12_subkeys, @function
chaskey12_subkeys:
	lw	a5,0(a2)
	lw	a4,12(a2)
	slli	a5,a5,1
	bge	a4,zero,.L71
	xori	a5,a5,135
.L71:
	sw	a5,0(a0)
	lw	a4,4(a2)
	lw	a3,0(a2)
	slli	a5,a5,1
	slli	a4,a4,1
	srli	a3,a3,31
	or	a4,a4,a3
	sw	a4,4(a0)
	lw	a4,8(a2)
	lw	a3,4(a2)
	slli	a4,a4,1
	srli	a3,a3,31
	or	a4,a4,a3
	sw	a4,8(a0)
	lw	a4,12(a2)
	lw	a3,8(a2)
	slli	a4,a4,1
	srli	a3,a3,31
	or	a4,a4,a3
	sw	a4,12(a0)
	bge	a4,zero,.L72
	xori	a5,a5,135
.L72:
	sw	a5,0(a1)
	lw	a5,4(a0)
	lw	a4,0(a0)
	slli	a5,a5,1
	srli	a4,a4,31
	or	a5,a5,a4
	sw	a5,4(a1)
	lw	a5,8(a0)
	lw	a4,4(a0)
	slli	a5,a5,1
	srli	a4,a4,31
	or	a5,a5,a4
	sw	a5,8(a1)
	lw	a5,12(a0)
	lw	a4,8(a0)
	slli	a5,a5,1
	srli	a4,a4,31
	or	a5,a5,a4
	sw	a5,12(a1)
	ret
	.size	chaskey12_subkeys, .-chaskey12_subkeys
	.align	2
	.globl	chaskey12_mac
	.type	chaskey12_mac, @function
chaskey12_mac:
	lw	t3,4(a4)
	lw	t1,8(a4)
	lw	a7,12(a4)
	lw	a4,0(a4)
	addi	sp,sp,-64
	sw	s0,56(sp)
	sw	s1,52(sp)
	sw	ra,60(sp)
	sw	s2,48(sp)
	sw	s3,44(sp)
	sw	s4,40(sp)
	sw	s5,36(sp)
	sw	a4,0(sp)
	sw	t3,4(sp)
	sw	t1,8(sp)
	sw	a7,12(sp)
	mv	s1,a0
	mv	s0,a1
	beq	a3,zero,.L88
	addi	t6,a3,-1
	srli	t6,t6,4
	beq	t6,zero,.L103
	slli	t6,t6,4
	add	t0,a2,t6
	mv	s2,sp
	addi	t5,sp,16
.L78:
	mv	a4,a2
	mv	t1,s2
.L76:
	lbu	a7,1(a4)
	lbu	t4,0(a4)
	lbu	a0,2(a4)
	lbu	a1,3(a4)
	slli	a7,a7,8
	lw	t3,0(t1)
	or	a7,a7,t4
	slli	a0,a0,16
	or	a0,a0,a7
	slli	a1,a1,24
	or	a1,a1,a0
	xor	a1,t3,a1
	sw	a1,0(t1)
	addi	t1,t1,4
	addi	a4,a4,4
	bne	t5,t1,.L76
	lw	a7,0(sp)
	lw	t1,4(sp)
	lw	t3,8(sp)
	lw	a1,12(sp)
	li	t4,12
.L77:
	srli	t2,a1,24
	slli	a4,t1,5
	srli	ra,t1,27
	slli	a0,a1,8
	add	a7,a7,t1
	add	t3,t3,a1
	or	a0,a0,t2
	or	a4,a4,ra
	xor	a4,a4,a7
	xor	a0,a0,t3
	slli	a1,a7,16
	srli	a7,a7,16
	add	t2,a4,t3
	or	a7,a1,a7
	srli	t3,a0,19
	slli	t1,a4,7
	slli	a1,a0,13
	srli	a4,a4,25
	or	a1,a1,t3
	or	t1,t1,a4
	add	a7,a7,a0
	slli	a4,t2,16
	srli	t3,t2,16
	addi	t4,t4,-1
	xor	a1,a1,a7
	xor	t1,t1,t2
	or	t3,t3,a4
	bne	t4,zero,.L77
	sw	a7,0(sp)
	sw	a1,12(sp)
	sw	t1,4(sp)
	sw	t3,8(sp)
	addi	a2,a2,16
	bne	a2,t0,.L78
	sub	t6,a3,t6
	j	.L74
.L88:
	li	t6,0
	mv	s2,sp
	addi	t5,sp,16
.L74:
	mv	t1,t5
	mv	a0,t5
	li	a4,0
	li	t3,16
.L81:
	sub	a1,a4,t6
	add	a7,a2,a4
	seqz	a1,a1
	bgeu	a4,t6,.L80
	lbu	a1,0(a7)
.L80:
	sb	a1,0(a0)
	addi	a4,a4,1
	addi	a0,a0,1
	bne	a4,t3,.L81
	beq	a3,zero,.L82
	beq	t6,a4,.L104
.L82:
	mv	s5,a6
	mv	s4,s2
	addi	t5,t5,16
	mv	a5,s2
	mv	a2,a6
.L83:
	lw	a3,0(a2)
	lw	a1,0(t1)
	lw	a4,0(a5)
	addi	t1,t1,4
	xor	a3,a3,a1
	xor	a4,a4,a3
	sw	a4,0(a5)
	addi	a2,a2,4
	addi	a5,a5,4
	bne	t5,t1,.L83
	li	s3,12
.L84:
	mv	a0,s2
	addi	s3,s3,-1
	call	chaskey12_round
	bne	s3,zero,.L84
	addi	a3,sp,16
.L85:
	lw	a5,0(s4)
	lw	a4,0(s5)
	addi	s4,s4,4
	addi	s5,s5,4
	xor	a5,a5,a4
	sw	a5,-4(s4)
	bne	a3,s4,.L85
	li	a2,16
	beq	s0,zero,.L73
.L86:
	andi	a5,s3,-4
	addi	a5,a5,32
	add	a5,a5,sp
	lw	a5,-32(a5)
	andi	a4,s3,3
	slli	a4,a4,3
	add	a3,s1,s3
	srl	a5,a5,a4
	sb	a5,0(a3)
	addi	s3,s3,1
	beq	s0,s3,.L73
	bne	s3,a2,.L86
.L73:
	lw	ra,60(sp)
	lw	s0,56(sp)
	lw	s1,52(sp)
	lw	s2,48(sp)
	lw	s3,44(sp)
	lw	s4,40(sp)
	lw	s5,36(sp)
	addi	sp,sp,64
	jr	ra
.L104:
	mv	a6,a5
	j	.L82
.L103:
	mv	t6,a3
	mv	s2,sp
	addi	t5,sp,16
	j	.L74
	.size	chaskey12_mac, .-chaskey12_mac
	.align	2
	.globl	memcpy
	.type	memcpy, @function
memcpy:
	beq	a2,zero,.L106
	add	a2,a0,a2
	mv	a5,a0
.L107:
	lbu	a4,0(a1)
	addi	a5,a5,1
	addi	a1,a1,1
	sb	a4,-1(a5)
	bne	a2,a5,.L107
.L106:
	ret
	.size	memcpy, .-memcpy
	.align	2
	.globl	memmove
	.type	memmove, @function
memmove:
	bltu	a0,a1,.L113
	addi	a5,a2,-1
	li	a6,-1
	beq	a2,zero,.L125
.L117:
	add	a4,a1,a5
	lbu	a3,0(a4)
	add	a4,a0,a5
	addi	a5,a5,-1
	sb	a3,0(a4)
	bne	a5,a6,.L117
.L119:
	ret
.L113:
	beq	a2,zero,.L119
	add	a2,a0,a2
	mv	a5,a0
.L116:
	lbu	a4,0(a1)
	addi	a5,a5,1
	addi	a1,a1,1
	sb	a4,-1(a5)
	bne	a5,a2,.L116
	ret
.L125:
	ret
	.size	memmove, .-memmove
	.align	2
	.globl	memset
	.type	memset, @function
memset:
	andi	a1,a1,0xff
	add	a4,a0,a2
	mv	a5,a0
	beq	a2,zero,.L132
.L128:
	addi	a5,a5,1
	sb	a1,-1(a5)
	bne	a4,a5,.L128
.L132:
	ret
	.size	memset, .-memset
	.align	2
	.globl	memcmp
	.type	memcmp, @function
memcmp:
	beq	a2,zero,.L137
	add	a2,a0,a2
	j	.L136
.L135:
	beq	a0,a2,.L137
.L136:
	lbu	a5,0(a0)
	lbu	a4,0(a1)
	addi	a0,a0,1
	addi	a1,a1,1
	beq	a5,a4,.L135
	sub	a0,a5,a4
	ret
.L137:
	li	a0,0
	ret
	.size	memcmp, .-memcmp
	.ident	"GCC: (xPack GNU RISC-V Embedded GCC x86_64) 13.2.0"
