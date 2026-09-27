	.file	"divmod.c"
	.option nopic
	.option norelax
	.attribute arch, "rv32i2p1_zmmul1p0"
	.attribute unaligned_access, 0
	.attribute stack_align, 16
	.text
	.align	2
	.globl	__udivsi3
	.type	__udivsi3, @function
__udivsi3:
	mv	a2,a0
	beq	a1,zero,.L5
	li	a0,0
	li	a4,31
	li	a5,0
	li	a7,1
	li	a6,-1
.L4:
	srl	a3,a2,a4
	andi	a3,a3,1
	slli	a5,a5,1
	or	a5,a3,a5
	sll	a3,a7,a4
	addi	a4,a4,-1
	bgtu	a1,a5,.L3
	sub	a5,a5,a1
	or	a0,a0,a3
.L3:
	bne	a4,a6,.L4
	ret
.L5:
	li	a0,-1
	ret
	.size	__udivsi3, .-__udivsi3
	.align	2
	.globl	__umodsi3
	.type	__umodsi3, @function
__umodsi3:
	mv	a3,a0
	beq	a1,zero,.L12
	li	a5,31
	li	a0,0
	li	a2,-1
.L11:
	srl	a4,a3,a5
	slli	a0,a0,1
	andi	a4,a4,1
	or	a0,a4,a0
	addi	a5,a5,-1
	bgtu	a1,a0,.L10
	sub	a0,a0,a1
.L10:
	bne	a5,a2,.L11
	ret
.L12:
	ret
	.size	__umodsi3, .-__umodsi3
	.align	2
	.globl	__divsi3
	.type	__divsi3, @function
__divsi3:
	beq	a1,zero,.L21
	srai	a4,a0,31
	srai	a5,a1,31
	xor	a7,a4,a0
	xor	a2,a5,a1
	sub	a7,a7,a4
	sub	a2,a2,a5
	li	a6,0
	li	a4,31
	li	a5,0
	li	t3,1
	li	t1,-1
.L19:
	srl	a3,a7,a4
	andi	a3,a3,1
	slli	a5,a5,1
	or	a5,a3,a5
	sll	a3,t3,a4
	addi	a4,a4,-1
	bgtu	a2,a5,.L18
	sub	a5,a5,a2
	or	a6,a6,a3
.L18:
	bne	a4,t1,.L19
	xor	a1,a1,a0
	mv	a0,a6
	blt	a1,zero,.L23
	ret
.L23:
	neg	a0,a6
	ret
.L21:
	li	a0,-1
	ret
	.size	__divsi3, .-__divsi3
	.align	2
	.globl	__modsi3
	.type	__modsi3, @function
__modsi3:
	mv	a7,a0
	beq	a1,zero,.L24
	srai	a4,a1,31
	srai	a5,a0,31
	xor	a2,a4,a1
	xor	a6,a5,a0
	sub	a6,a6,a5
	sub	a2,a2,a4
	li	a5,0
	li	a4,31
	li	a1,-1
.L29:
	srl	a3,a6,a4
	slli	a5,a5,1
	andi	a3,a3,1
	or	a5,a3,a5
	addi	a4,a4,-1
	bltu	a5,a2,.L28
	sub	a5,a5,a2
.L28:
	bne	a4,a1,.L29
	mv	a0,a5
	blt	a7,zero,.L33
.L24:
	ret
.L33:
	neg	a0,a5
	ret
	.size	__modsi3, .-__modsi3
	.ident	"GCC: (xPack GNU RISC-V Embedded GCC x86_64) 13.2.0"
