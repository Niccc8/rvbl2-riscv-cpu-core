	.file	"main.c"
	.option nopic
	.option norelax
	.attribute arch, "rv32i2p1_zmmul1p0"
	.attribute unaligned_access, 0
	.attribute stack_align, 16
	.text
	.align	2
	.type	hot_find, @function
hot_find:
	lw	a3,4(a0)
	lw	a2,8(a0)
	lw	a1,0(a0)
	slli	a6,a3,3
	add	a6,a6,a3
	slli	a5,a2,2
	slli	a4,a6,7
	add	a5,a5,a2
	sub	a4,a4,a6
	slli	a5,a5,2
	slli	a6,a1,2
	slli	a4,a4,2
	sub	a5,a5,a2
	add	a6,a6,a1
	sub	a4,a4,a3
	slli	a5,a5,4
	slli	a6,a6,3
	slli	a4,a4,2
	sub	a5,a5,a2
	add	a6,a6,a1
	add	a4,a4,a3
	slli	a5,a5,4
	sub	a5,a5,a2
	slli	a6,a6,7
	slli	a4,a4,2
	sub	a6,a6,a1
	sub	a4,a4,a3
	slli	a7,a5,6
	add	a5,a5,a7
	slli	a6,a6,2
	slli	a4,a4,2
	sub	a6,a6,a1
	sub	a4,a4,a3
	slli	a5,a5,5
	sub	a5,a5,a2
	slli	t1,a6,5
	slli	a4,a4,6
	sub	t1,t1,a6
	add	a4,a4,a3
	slli	a6,a5,3
	add	a5,a5,a6
	slli	a7,a4,4
	slli	a6,t1,8
	sub	a6,a6,t1
	sub	a7,a7,a4
	slli	t1,a5,3
	slli	a4,a6,4
	add	a5,a5,t1
	slli	a6,a7,3
	add	a4,a4,a1
	sub	a3,a6,a3
	slli	a5,a5,2
	xor	a4,a4,a3
	add	a5,a5,a2
	xor	a4,a4,a5
	slli	a5,a4,8
	sub	a5,a5,a4
	slli	a5,a5,4
	sub	a5,a5,a4
	slli	a5,a5,2
	sub	a5,a5,a4
	slli	a5,a5,4
	add	a5,a5,a4
	slli	a5,a5,3
	add	a5,a5,a4
	slli	a3,a5,2
	add	a5,a5,a3
	slli	a5,a5,2
	sub	a5,a5,a4
	slli	a5,a5,4
	sub	a5,a5,a4
	srli	a5,a5,26
	li	a1,-251658240
	li	t5,-251658240
	lui	a3,%hi(.LANCHOR0)
	lui	t1,%hi(.LANCHOR1)
	addi	t4,a5,8
	addi	a3,a3,%lo(.LANCHOR0)
	addi	a1,a1,8
	addi	t5,t5,4
	li	t0,63
	addi	t1,t1,%lo(.LANCHOR1)
	li	t3,1
.L6:
	lw	a4,0(a1)
	andi	a2,a5,63
	andi	a4,a4,2
	beq	a4,zero,.L2
	lw	t6,0(t5)
	sw	zero,0(a1)
	lw	a4,0(a3)
	lw	a6,4(a3)
	andi	a7,a4,63
	sub	a6,a4,a6
	add	a7,t1,a7
	addi	a4,a4,1
	bgtu	a6,t0,.L3
	sw	a4,0(a3)
	sb	t6,0(a7)
.L2:
	add	a4,a3,a2
	lbu	a4,12(a4)
	addi	a5,a5,1
	beq	a4,zero,.L7
	beq	a4,t3,.L13
.L5:
	bne	a5,t4,.L6
.L7:
	li	a0,-1
	ret
.L13:
	slli	a4,a2,1
	add	a4,a4,a2
	slli	a4,a4,2
	add	a4,t1,a4
	lw	a7,64(a4)
	lw	a6,0(a0)
	bne	a7,a6,.L5
	lw	a7,68(a4)
	lw	a6,4(a0)
	bne	a7,a6,.L5
	lw	a6,72(a4)
	lw	a4,8(a0)
	bne	a6,a4,.L5
	mv	a0,a2
	ret
.L3:
	lw	a4,8(a3)
	addi	a4,a4,1
	sw	a4,8(a3)
	j	.L2
	.size	hot_find, .-hot_find
	.align	2
	.type	seen_get, @function
seen_get:
	lw	a3,4(a0)
	lw	a2,8(a0)
	lw	a1,0(a0)
	slli	a6,a3,3
	add	a6,a6,a3
	slli	a5,a2,2
	slli	a4,a6,7
	add	a5,a5,a2
	sub	a4,a4,a6
	slli	a5,a5,2
	slli	a6,a1,2
	slli	a4,a4,2
	sub	a5,a5,a2
	add	a6,a6,a1
	sub	a4,a4,a3
	slli	a5,a5,4
	slli	a6,a6,3
	slli	a4,a4,2
	sub	a5,a5,a2
	add	a6,a6,a1
	add	a4,a4,a3
	slli	a5,a5,4
	sub	a5,a5,a2
	slli	a6,a6,7
	slli	a4,a4,2
	sub	a6,a6,a1
	sub	a4,a4,a3
	slli	a7,a5,6
	add	a5,a5,a7
	slli	a6,a6,2
	slli	a4,a4,2
	sub	a6,a6,a1
	sub	a4,a4,a3
	slli	a5,a5,5
	sub	a5,a5,a2
	slli	t1,a6,5
	slli	a4,a4,6
	sub	t1,t1,a6
	add	a4,a4,a3
	slli	a6,a5,3
	add	a5,a5,a6
	slli	a7,a4,4
	slli	a6,t1,8
	sub	a6,a6,t1
	sub	a7,a7,a4
	slli	t1,a5,3
	slli	a4,a6,4
	add	a5,a5,t1
	slli	a6,a7,3
	sub	a3,a6,a3
	add	a4,a4,a1
	slli	a5,a5,2
	xor	a4,a4,a3
	add	a5,a5,a2
	xor	a4,a4,a5
	slli	a5,a4,8
	sub	a5,a5,a4
	slli	a5,a5,4
	sub	a5,a5,a4
	slli	a5,a5,2
	sub	a5,a5,a4
	slli	a5,a5,4
	add	a5,a5,a4
	slli	a5,a5,3
	add	a5,a5,a4
	slli	a3,a5,2
	add	a5,a5,a3
	slli	a5,a5,2
	sub	a5,a5,a4
	slli	a5,a5,4
	sub	a5,a5,a4
	srli	a5,a5,26
	li	a7,-251658240
	li	t4,-251658240
	lui	a1,%hi(.LANCHOR0)
	lui	a6,%hi(.LANCHOR1)
	addi	t3,a5,8
	addi	a1,a1,%lo(.LANCHOR0)
	addi	a7,a7,8
	addi	t4,t4,4
	li	t5,63
	addi	a6,a6,%lo(.LANCHOR1)
.L19:
	lw	a4,0(a7)
	andi	a3,a5,63
	andi	a4,a4,2
	beq	a4,zero,.L15
	lw	t6,0(t4)
	sw	zero,0(a7)
	lw	a4,0(a1)
	lw	a2,4(a1)
	andi	t1,a4,63
	sub	a2,a4,a2
	add	t1,a6,t1
	addi	a4,a4,1
	bgtu	a2,t5,.L16
	sw	a4,0(a1)
	sb	t6,0(t1)
.L15:
	add	a2,a1,a3
	slli	a4,a3,2
	lbu	a2,76(a2)
	add	a4,a4,a3
	slli	a4,a4,2
	add	a4,a6,a4
	addi	a5,a5,1
	beq	a2,zero,.L20
	lw	t1,832(a4)
	lw	a2,0(a0)
	beq	t1,a2,.L25
.L18:
	bne	a5,t3,.L19
.L20:
	li	a0,-1
	ret
.L25:
	lw	t1,836(a4)
	lw	a2,4(a0)
	bne	t1,a2,.L18
	lw	a2,840(a4)
	lw	a4,8(a0)
	bne	a2,a4,.L18
	mv	a0,a3
	ret
.L16:
	lw	a4,8(a1)
	addi	a4,a4,1
	sw	a4,8(a1)
	j	.L15
	.size	seen_get, .-seen_get
	.align	2
	.type	seen_put, @function
seen_put:
	lw	a3,4(a0)
	lw	a6,8(a0)
	lw	a7,0(a0)
	slli	t1,a3,3
	add	t1,t1,a3
	slli	a5,a6,2
	slli	a4,t1,7
	add	a5,a5,a6
	sub	a4,a4,t1
	slli	a5,a5,2
	slli	t1,a7,2
	slli	a4,a4,2
	sub	a5,a5,a6
	add	t1,t1,a7
	sub	a4,a4,a3
	slli	a5,a5,4
	slli	t1,t1,3
	slli	a4,a4,2
	sub	a5,a5,a6
	add	t1,t1,a7
	add	a4,a4,a3
	slli	a5,a5,4
	sub	a5,a5,a6
	slli	t1,t1,7
	slli	a4,a4,2
	sub	t1,t1,a7
	sub	a4,a4,a3
	slli	t3,a5,6
	add	a5,a5,t3
	slli	t1,t1,2
	slli	a4,a4,2
	sub	t1,t1,a7
	sub	a4,a4,a3
	slli	a5,a5,5
	sub	a5,a5,a6
	slli	t4,t1,5
	slli	a4,a4,6
	sub	t4,t4,t1
	add	a4,a4,a3
	slli	t1,a5,3
	add	a5,a5,t1
	slli	t3,a4,4
	slli	t1,t4,8
	sub	t1,t1,t4
	sub	t3,t3,a4
	slli	t4,a5,3
	slli	a4,t1,4
	add	a5,a5,t4
	slli	t1,t3,3
	sub	a3,t1,a3
	add	a4,a4,a7
	slli	a5,a5,2
	xor	a4,a4,a3
	add	a5,a5,a6
	xor	a4,a4,a5
	slli	a5,a4,8
	sub	a5,a5,a4
	slli	a5,a5,4
	sub	a5,a5,a4
	slli	a5,a5,2
	sub	a5,a5,a4
	slli	a5,a5,4
	add	a5,a5,a4
	slli	a5,a5,3
	add	a5,a5,a4
	slli	a3,a5,2
	add	a5,a5,a3
	slli	a5,a5,2
	sub	a5,a5,a4
	slli	a5,a5,4
	sub	a5,a5,a4
	addi	sp,sp,-16
	srli	a5,a5,26
	li	t3,-251658240
	li	t2,-251658240
	lui	t1,%hi(.LANCHOR0)
	lui	a7,%hi(.LANCHOR1)
	sw	s0,12(sp)
	sw	s1,8(sp)
	sw	s2,4(sp)
	addi	t0,a5,8
	li	t4,0
	li	t6,0
	li	t5,0
	addi	t1,t1,%lo(.LANCHOR0)
	addi	a7,a7,%lo(.LANCHOR1)
	addi	t3,t3,8
	addi	t2,t2,4
	li	s0,63
	j	.L32
.L30:
	add	a4,a4,a6
	slli	a4,a4,2
	add	a4,a7,a4
	lw	a4,844(a4)
	beq	t4,zero,.L36
	bgeu	a4,t6,.L31
.L36:
	mv	t6,a4
	mv	t5,a6
.L31:
	addi	a5,a5,1
	li	t4,1
	beq	a5,t0,.L29
.L32:
	lw	a4,0(t3)
	andi	a6,a5,63
	andi	a4,a4,2
	beq	a4,zero,.L27
	lw	s1,0(t2)
	sw	zero,0(t3)
	lw	a4,0(t1)
	lw	a3,4(t1)
	sub	a3,a4,a3
	bgtu	a3,s0,.L28
	andi	a3,a4,63
	add	a3,a7,a3
	addi	a4,a4,1
	sw	a4,0(t1)
	sb	s1,0(a3)
.L27:
	add	a4,t1,a6
	lbu	a4,76(a4)
	beq	a4,zero,.L34
	slli	a4,a6,2
	add	a3,a4,a6
	slli	a3,a3,2
	add	a3,a7,a3
	lw	s1,832(a3)
	lw	s2,0(a0)
	bne	s1,s2,.L30
	lw	s1,4(a0)
	lw	s2,836(a3)
	bne	s2,s1,.L30
	lw	s1,840(a3)
	lw	a3,8(a0)
	bne	s1,a3,.L30
.L34:
	mv	t5,a6
.L29:
	slli	a5,t5,2
	add	a5,a5,t5
	slli	a5,a5,2
	add	a7,a7,a5
	add	t1,t1,t5
	li	a5,1
	sb	a5,76(t1)
	lw	a6,0(a0)
	lw	a3,4(a0)
	lw	a4,8(a0)
	lw	s0,12(sp)
	sw	a6,832(a7)
	sw	a3,836(a7)
	sw	a4,840(a7)
	sw	a1,848(a7)
	sw	a2,844(a7)
	lw	s1,8(sp)
	lw	s2,4(sp)
	addi	sp,sp,16
	jr	ra
.L28:
	lw	a4,8(t1)
	addi	a4,a4,1
	sw	a4,8(t1)
	j	.L27
	.size	seen_put, .-seen_put
	.align	2
	.type	vt_add, @function
vt_add:
	li	a5,-251658240
	lw	a4,8(a5)
	addi	a5,a5,8
	andi	a4,a4,2
	bne	a4,zero,.L56
	lui	t3,%hi(.LANCHOR0)
	addi	t3,t3,%lo(.LANCHOR0)
.L43:
	lw	a2,140(t3)
	beq	a2,zero,.L58
	lui	a7,%hi(.LANCHOR2)
	addi	a7,a7,%lo(.LANCHOR2)
	lw	a6,0(a0)
	addi	a5,a7,-1984
	li	a4,0
	j	.L50
.L47:
	addi	a4,a4,1
	addi	a5,a5,20
	beq	a2,a4,.L59
.L50:
	lw	a3,0(a5)
	bne	a3,a6,.L47
	lw	t1,4(a5)
	lw	a3,4(a0)
	bne	t1,a3,.L47
	lw	t1,8(a5)
	lw	a3,8(a0)
	bne	t1,a3,.L47
	slli	a5,a4,2
	add	a5,a5,a4
	slli	a5,a5,2
	add	a7,a7,a5
	lw	a5,-1972(a7)
	lw	a4,-1968(a7)
	addi	a5,a5,1
	sw	a5,-1972(a7)
	bltu	a4,a1,.L48
	ret
.L59:
	li	a5,4
	beq	a2,a5,.L42
	addi	a4,a2,1
.L46:
	slli	a5,a2,2
	lw	a3,0(a0)
	add	a5,a5,a2
	slli	a5,a5,2
	add	a7,a7,a5
	sw	a3,-1984(a7)
	lw	a5,4(a0)
	sw	a4,140(t3)
	li	a4,1
	sw	a5,-1980(a7)
	lw	a5,8(a0)
	sw	a4,-1972(a7)
	sw	a1,-1968(a7)
	sw	a5,-1976(a7)
.L42:
	ret
.L56:
	li	a3,-251658240
	lui	t3,%hi(.LANCHOR0)
	addi	t3,t3,%lo(.LANCHOR0)
	lw	a6,4(a3)
	sw	zero,0(a5)
	lw	a5,0(t3)
	lw	a4,4(t3)
	li	a2,63
	sub	a4,a5,a4
	bgtu	a4,a2,.L44
	lui	a4,%hi(.LANCHOR1)
	andi	a3,a5,63
	addi	a4,a4,%lo(.LANCHOR1)
	addi	a5,a5,1
	add	a4,a4,a3
	sw	a5,0(t3)
	sb	a6,0(a4)
	j	.L43
.L44:
	lw	a5,8(t3)
	addi	a5,a5,1
	sw	a5,8(t3)
	j	.L43
.L48:
	sw	a1,-1968(a7)
	ret
.L58:
	lui	a7,%hi(.LANCHOR2)
	li	a4,1
	addi	a7,a7,%lo(.LANCHOR2)
	j	.L46
	.size	vt_add, .-vt_add
	.align	2
	.type	get_epc, @function
get_epc:
	lhu	a5,2(a1)
	lhu	a4,0(a1)
	slli	a5,a5,16
	or	a5,a5,a4
	sw	a5,0(a0)
	lhu	a5,6(a1)
	lhu	a4,4(a1)
	slli	a5,a5,16
	or	a5,a5,a4
	sw	a5,4(a0)
	lhu	a5,10(a1)
	lhu	a4,8(a1)
	slli	a5,a5,16
	or	a5,a5,a4
	sw	a5,8(a0)
	ret
	.size	get_epc, .-get_epc
	.align	2
	.type	push8.part.0, @function
push8.part.0:
	li	t4,-251658240
	lui	a2,%hi(.LANCHOR0)
	lui	a7,%hi(.LANCHOR2)
	li	a5,0
	addi	a2,a2,%lo(.LANCHOR0)
	addi	a7,a7,%lo(.LANCHOR2)
	li	t1,3
	li	t3,8
	addi	t4,t4,8
.L67:
	lw	a3,144(a2)
	add	a4,a0,a5
	lbu	a6,0(a4)
	andi	a4,a3,127
	addi	a1,a3,1
	add	a4,a7,a4
	sw	a1,144(a2)
	sb	a6,-1904(a4)
	beq	a5,t1,.L74
.L62:
	addi	a5,a5,1
	bne	a5,t3,.L67
	li	a5,-251658240
	lw	a4,8(a5)
	addi	a5,a5,8
	andi	a4,a4,2
	beq	a4,zero,.L61
	li	a4,-251658240
	lw	a0,4(a4)
	sw	zero,0(a5)
	lw	a3,0(a2)
	lw	a5,4(a2)
	li	a1,63
	sub	a5,a3,a5
	bgtu	a5,a1,.L69
	lui	a5,%hi(.LANCHOR1)
	andi	a4,a3,63
	addi	a5,a5,%lo(.LANCHOR1)
	addi	a3,a3,1
	add	a5,a5,a4
	sw	a3,0(a2)
	sb	a0,0(a5)
	ret
.L74:
	lw	a5,0(t4)
	li	a4,-251658240
	andi	a1,a1,127
	andi	a5,a5,2
	addi	a4,a4,4
	li	a6,63
	addi	a3,a3,2
	add	a1,a7,a1
	bne	a5,zero,.L63
	lbu	a4,4(a0)
	sw	a3,144(a2)
	li	a5,4
	sb	a4,-1904(a1)
	j	.L62
.L61:
	ret
.L63:
	lw	t5,0(a4)
	sw	zero,0(t4)
	lw	a5,0(a2)
	lw	a3,4(a2)
	andi	a1,a5,63
	sub	a3,a5,a3
	addi	a4,a5,1
	lui	a5,%hi(.LANCHOR1)
	addi	a5,a5,%lo(.LANCHOR1)
	add	a5,a5,a1
	bgtu	a3,a6,.L64
	sb	t5,0(a5)
	sw	a4,0(a2)
	li	a5,4
	j	.L67
.L64:
	lw	a5,8(a2)
	addi	a5,a5,1
	sw	a5,8(a2)
	li	a5,4
	j	.L67
.L69:
	lw	a5,8(a2)
	addi	a5,a5,1
	sw	a5,8(a2)
	ret
	.size	push8.part.0, .-push8.part.0
	.align	2
	.type	mac_step, @function
mac_step:
	addi	sp,sp,-64
	sw	s0,56(sp)
	lui	s0,%hi(.LANCHOR0)
	sw	s1,52(sp)
	sw	s3,44(sp)
	sw	s4,40(sp)
	sw	s5,36(sp)
	addi	s0,s0,%lo(.LANCHOR0)
	li	s1,-251658240
	lui	s5,%hi(.LANCHOR1)
	li	s4,16777216
	li	s3,65536
	sw	s2,48(sp)
	sw	s6,32(sp)
	sw	ra,60(sp)
	sw	s7,28(sp)
	addi	s6,a0,-1
	addi	s2,s0,148
	addi	s1,s1,8
	addi	s5,s5,%lo(.LANCHOR1)
	addi	s4,s4,-1
	addi	s3,s3,-1
	j	.L76
.L79:
	addi	s6,s6,-1
	li	a5,-1
	beq	s6,a5,.L75
.L76:
	lw	a5,164(s0)
	beq	a5,zero,.L75
	mv	a0,s2
	call	chaskey12_round
	lw	a5,0(s1)
	andi	a5,a5,2
	beq	a5,zero,.L77
	li	a3,-251658240
	lw	a1,4(a3)
	sw	zero,0(s1)
	lw	a5,0(s0)
	lw	a4,4(s0)
	li	a2,63
	sub	a4,a5,a4
	bgtu	a4,a2,.L78
	andi	a4,a5,63
	add	a4,s5,a4
	addi	a5,a5,1
	sw	a5,0(s0)
	sb	a1,0(a4)
.L77:
	lw	a5,164(s0)
	addi	a5,a5,-1
	sw	a5,164(s0)
	bne	a5,zero,.L79
	lw	a4,184(s0)
	lw	a5,144(s0)
	lw	s7,148(s0)
	lw	a3,168(s0)
	sub	a5,a5,a4
	li	a4,120
	xor	s7,s7,a3
	bgtu	a5,a4,.L103
	addi	a0,s0,192
	call	push8.part.0
.L81:
	lw	a5,0(s1)
	andi	a5,a5,2
	beq	a5,zero,.L82
	li	a4,-251658240
	lw	a1,4(a4)
	sw	zero,0(s1)
	lw	a3,0(s0)
	lw	a5,4(s0)
	li	a2,63
	sub	a5,a3,a5
	bgtu	a5,a2,.L83
	lui	a5,%hi(.LANCHOR1)
	andi	a4,a3,63
	addi	a5,a5,%lo(.LANCHOR1)
	addi	a3,a3,1
	add	a5,a5,a4
	sw	a3,0(s0)
	sb	a1,0(a5)
.L82:
	lbu	a5,193(s0)
	andi	a3,s7,0xff
	srli	a4,s7,8
	slli	a3,a3,8
	andi	a4,a4,0xff
	slli	a4,a4,16
	or	a5,a5,a3
	or	a5,a5,a4
	srli	a4,s7,16
	slli	a4,a4,24
	and	a5,a5,s4
	or	a5,a5,a4
	srli	s7,s7,24
	sw	a5,0(sp)
	sb	s7,4(sp)
	li	a5,65
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a2, a5, s3
# 0 "" 2
 #NO_APP
	sb	a5,8(sp)
	mv	a4,sp
	addi	a5,sp,9
	addi	a1,sp,14
.L84:
	lbu	a3,0(a4)
	sb	a3,0(a5)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a2, a3, a2
# 0 "" 2
 #NO_APP
	addi	a5,a5,1
	addi	a4,a4,1
	bne	a1,a5,.L84
	sh	a2,14(sp)
	lw	a5,0(s1)
	andi	a5,a5,2
	beq	a5,zero,.L85
	li	a4,-251658240
	lw	a1,4(a4)
	sw	zero,0(s1)
	lw	a3,0(s0)
	lw	a5,4(s0)
	li	a2,63
	sub	a5,a3,a5
	bgtu	a5,a2,.L86
	lui	a5,%hi(.LANCHOR1)
	andi	a4,a3,63
	addi	a5,a5,%lo(.LANCHOR1)
	addi	a3,a3,1
	add	a5,a5,a4
	sw	a3,0(s0)
	sb	a1,0(a5)
.L85:
	lw	a5,144(s0)
	lw	a3,184(s0)
	li	a4,120
	sub	a5,a5,a3
	bgtu	a5,a4,.L104
	addi	a0,sp,8
	call	push8.part.0
.L88:
	lw	a5,200(s0)
	addi	s6,s6,-1
	addi	a5,a5,1
	sw	a5,200(s0)
	li	a5,-1
	bne	s6,a5,.L76
.L75:
	lw	ra,60(sp)
	lw	s0,56(sp)
	lw	s1,52(sp)
	lw	s2,48(sp)
	lw	s3,44(sp)
	lw	s4,40(sp)
	lw	s5,36(sp)
	lw	s6,32(sp)
	lw	s7,28(sp)
	addi	sp,sp,64
	jr	ra
.L78:
	lw	a5,8(s0)
	addi	a5,a5,1
	sw	a5,8(s0)
	j	.L77
.L104:
	lw	a5,188(s0)
	addi	a5,a5,1
	sw	a5,188(s0)
	j	.L88
.L103:
	lw	a5,188(s0)
	addi	a5,a5,1
	sw	a5,188(s0)
	j	.L81
.L86:
	lw	a5,8(s0)
	addi	a5,a5,1
	sw	a5,8(s0)
	j	.L85
.L83:
	lw	a5,8(s0)
	addi	a5,a5,1
	sw	a5,8(s0)
	j	.L82
	.size	mac_step, .-mac_step
	.align	2
	.type	finalize, @function
finalize:
	addi	sp,sp,-80
	sw	s0,72(sp)
	lui	s0,%hi(.LANCHOR0)
	addi	s0,s0,%lo(.LANCHOR0)
	lw	a4,204(s0)
	lui	a5,%hi(.LANCHOR3)
	addi	a5,a5,%lo(.LANCHOR3)
	add	a5,a5,a4
	sw	s4,56(sp)
	lbu	s4,0(a5)
	lw	a5,140(s0)
	sw	s5,52(sp)
	sw	s7,44(sp)
	sw	ra,76(sp)
	sw	s2,64(sp)
	sw	s3,60(sp)
	sw	s6,48(sp)
	sw	zero,212(s0)
	sw	zero,216(s0)
	lw	s7,208(s0)
	mv	s5,s4
	beq	a5,zero,.L106
	sw	s1,68(sp)
	sw	s8,40(sp)
	lui	s1,%hi(.LANCHOR2)
	li	s8,-251658240
	li	s6,-251658240
	lui	a5,%hi(.LANCHOR2-1984)
	lui	s2,%hi(.LANCHOR1)
	lui	s3,%hi(.LANCHOR4)
	sw	s9,36(sp)
	sw	s10,32(sp)
	sw	s11,28(sp)
	addi	s1,s1,%lo(.LANCHOR2)
	addi	s11,a5,%lo(.LANCHOR2-1984)
	li	s10,0
	li	s9,-1
	addi	s8,s8,8
	addi	s6,s6,4
	addi	s2,s2,%lo(.LANCHOR1)
	addi	s3,s3,%lo(.LANCHOR4)
.L113:
	lw	a5,0(s8)
	andi	a5,a5,2
	beq	a5,zero,.L107
	lw	a1,0(s6)
	sw	zero,0(s8)
	lw	a2,0(s0)
	lw	a5,4(s0)
	li	a4,63
	sub	a5,a2,a5
	bgtu	a5,a4,.L108
	andi	a5,a2,63
	add	a5,s2,a5
	addi	a2,a2,1
	sw	a2,0(s0)
	sb	a1,0(a5)
.L107:
	mv	a0,s11
	call	seen_get
	blt	a0,zero,.L109
	slli	a5,a0,2
	add	a5,a5,a0
	slli	a5,a5,2
	add	a5,s2,a5
	lw	a1,848(a5)
	lw	a2,0(s3)
	beq	a1,a2,.L148
.L109:
	blt	s9,zero,.L112
.L151:
	slli	a5,s9,2
	add	a5,a5,s9
	slli	a5,a5,2
	add	a5,s1,a5
	lw	a1,12(s11)
	lw	a2,-1972(a5)
	bgtu	a1,a2,.L112
	beq	a1,a2,.L149
.L110:
	lw	a5,140(s0)
	addi	s10,s10,1
	addi	s11,s11,20
	bgtu	a5,s10,.L113
	beq	s7,zero,.L150
	lw	s1,68(sp)
	lw	s8,40(sp)
	lw	s9,36(sp)
	lw	s10,32(sp)
	lw	s11,28(sp)
.L115:
	li	s7,0
	li	s5,0
	li	s6,0
	li	s2,0
	li	a5,7
	li	s3,6
.L116:
	lw	a3,240(s0)
	li	a4,-251658240
	addi	a4,a4,8
	addi	a3,a3,1
	sw	a3,240(s0)
	lw	a3,0(a4)
	andi	a3,a3,2
	beq	a3,zero,.L126
	li	a3,-251658240
	lw	a0,4(a3)
	sw	zero,0(a4)
	lw	a2,0(s0)
	lw	a4,4(s0)
	li	a1,63
	sub	a4,a2,a4
	bgtu	a4,a1,.L127
	lui	a4,%hi(.LANCHOR1)
	andi	a3,a2,63
	addi	a4,a4,%lo(.LANCHOR1)
	addi	a2,a2,1
	add	a4,a4,a3
	sw	a2,0(s0)
	sb	a0,0(a4)
.L126:
	lbu	a4,244(s0)
	slli	s4,s4,4
	or	a5,a5,s4
	slli	a3,s3,8
	andi	a5,a5,0xff
	or	a4,a4,a3
	slli	a5,a5,16
	slli	a3,s2,24
	or	a5,a4,a5
	or	a5,a5,a3
	li	a0,12
	sw	a5,0(sp)
	sb	s6,4(sp)
	call	mac_step
	li	a3,65536
	li	a5,86
	addi	a3,a3,-1
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a3, a5, a3
# 0 "" 2
 #NO_APP
	sb	a5,8(sp)
	mv	a4,sp
	addi	a5,sp,9
	addi	a1,sp,14
.L128:
	lbu	a2,0(a4)
	sb	a2,0(a5)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a3, a2, a3
# 0 "" 2
 #NO_APP
	addi	a5,a5,1
	addi	a4,a4,1
	bne	a1,a5,.L128
	lw	a5,248(s0)
	sh	a3,14(sp)
	beq	a5,zero,.L129
	lui	a5,%hi(.LANCHOR4)
	lw	a5,%lo(.LANCHOR4)(a5)
	lw	t4,168(s0)
	lhu	t5,12(sp)
	lw	a2,252(s0)
	lw	a1,256(s0)
	lw	t3,172(s0)
	slli	a5,a5,16
	xor	a2,a2,t4
	lw	a3,260(s0)
	lw	t1,176(s0)
	lw	a4,264(s0)
	lw	a7,180(s0)
	or	a5,a5,t5
	li	t4,50331648
	lw	a0,8(sp)
	xor	a1,a1,t3
	lw	a6,200(s0)
	or	a5,a5,t4
	xor	a5,a5,a1
	lw	a1,12(sp)
	xor	a3,a3,t1
	xor	a4,a4,a7
	xor	a2,a2,a0
	xor	a3,a3,a6
	xori	a4,a4,1
	sw	a5,152(s0)
	li	a5,12
	sw	a0,192(s0)
	sw	a1,196(s0)
	sw	a2,148(s0)
	sw	a3,156(s0)
	sw	a4,160(s0)
	sw	a5,164(s0)
.L130:
	lw	a4,244(s0)
	lw	a5,268(s0)
	or	s5,s5,s7
	addi	a4,a4,1
	andi	a5,a5,128
	or	a5,a5,s5
	andi	a4,a4,255
	sw	a4,244(s0)
	sw	a5,268(s0)
	lw	ra,76(sp)
	lw	s0,72(sp)
	li	a4,-268435456
	sw	a5,0(a4)
	lw	s2,64(sp)
	lw	s3,60(sp)
	lw	s4,56(sp)
	lw	s5,52(sp)
	lw	s6,48(sp)
	lw	s7,44(sp)
	addi	sp,sp,80
	jr	ra
.L148:
	lw	a2,220(s0)
	lw	a1,844(a5)
	lw	a0,4(s3)
	sub	a1,a2,a1
	sgtu	a5,a1,a2
	neg	a2,a5
	bne	a5,zero,.L110
	bne	a2,zero,.L109
	bgtu	a0,a1,.L110
	bge	s9,zero,.L151
.L112:
	mv	s9,s10
	j	.L110
.L108:
	lw	a5,8(s0)
	addi	a5,a5,1
	sw	a5,8(s0)
	j	.L107
.L150:
	blt	s9,zero,.L147
	slli	s2,s9,2
	add	s2,s2,s9
	lui	a5,%hi(.LANCHOR2-1984)
	slli	s2,s2,2
	addi	a5,a5,%lo(.LANCHOR2-1984)
	add	s9,a5,s2
	mv	a0,s9
	call	seen_get
	add	s1,s1,s2
	lw	a5,-1984(s1)
	mv	a4,a0
	mv	a0,s9
	andi	s1,a5,7
	mv	s2,a4
	call	hot_find
	lui	a5,%hi(.LANCHOR4)
	addi	a5,a5,%lo(.LANCHOR4)
	lw	a1,0(a5)
	lw	a2,220(s0)
	blt	a0,zero,.L152
	li	s5,96
	li	s6,0
	li	s2,0
	li	s3,3
.L118:
	mv	a0,s9
	call	seen_put
	andi	a5,s1,0xff
	lw	s8,40(sp)
	lw	s1,68(sp)
	lw	s9,36(sp)
	lw	s10,32(sp)
	lw	s11,28(sp)
	j	.L116
.L129:
	lw	a5,144(s0)
	lw	a3,184(s0)
	li	a4,120
	sub	a5,a5,a3
	bgtu	a5,a4,.L153
	addi	a0,sp,8
	call	push8.part.0
	j	.L130
.L149:
	lw	a2,16(s11)
	lw	a5,-1968(a5)
	bleu	a2,a5,.L110
	mv	s9,s10
	j	.L110
.L127:
	lw	a4,8(s0)
	addi	a4,a4,1
	sw	a4,8(s0)
	j	.L126
.L106:
	bne	s7,zero,.L115
	li	s7,0
	bne	s4,zero,.L132
.L157:
	li	s6,0
	li	s2,0
	li	a5,7
	li	s3,5
	j	.L116
.L132:
	li	s5,32
	li	s6,0
	li	s2,0
	li	a5,7
	li	s3,1
	j	.L116
.L152:
	blt	s2,zero,.L119
	slli	a3,s2,2
	add	a3,a3,s2
	lui	a4,%hi(.LANCHOR1)
	slli	a3,a3,2
	addi	a4,a4,%lo(.LANCHOR1)
	add	a4,a4,a3
	lw	a3,848(a4)
	beq	a3,a1,.L119
	lw	a0,844(a4)
	slli	a3,a3,1
	slli	a4,a1,1
	add	a4,s0,a4
	add	a3,s0,a3
	sub	a0,a2,a0
	lhu	a4,224(a4)
	lhu	a3,224(a3)
	ble	a0,zero,.L154
	sub	a4,a4,a3
	srai	a7,a4,31
	lw	a6,8(a5)
	xor	a4,a7,a4
	li	a3,360448
	sub	a4,a4,a7
	addi	a3,a3,-448
	mulh	t1,a4,a3
	mulhu	a7,a0,a6
	mul	a4,a4,a3
	mul	a0,a0,a6
	bgtu	t1,a7,.L135
	bne	t1,a7,.L119
	bleu	a4,a0,.L119
.L135:
	li	s5,96
	li	s6,0
	li	s2,0
	li	s3,4
	j	.L118
.L154:
	bne	a4,a3,.L135
.L119:
	li	a4,4
	beq	s1,a4,.L155
	li	a4,5
	beq	s1,a4,.L156
	beq	s4,s1,.L124
.L123:
	slli	a4,s4,1
	add	a5,a5,a4
	lhu	s6,12(a5)
	li	s5,32
	li	s7,16
	andi	s2,s6,0xff
	li	s3,2
	srli	s6,s6,8
	j	.L118
.L147:
	lw	s1,68(sp)
	lw	s8,40(sp)
	lw	s9,36(sp)
	lw	s10,32(sp)
	lw	s11,28(sp)
	li	s7,0
	bne	s4,zero,.L132
	j	.L157
.L153:
	lw	a5,188(s0)
	addi	a5,a5,1
	sw	a5,188(s0)
	j	.L130
.L156:
	addi	a4,s4,-2
	li	a3,1
	bgtu	a4,a3,.L123
.L124:
	slli	a4,s1,1
	add	a5,a5,a4
	lhu	s6,12(a5)
	li	s5,0
	li	s7,16
	andi	s2,s6,0xff
	li	s3,0
	srli	s6,s6,8
	j	.L118
.L155:
	li	a4,1
	bne	s4,a4,.L123
	j	.L124
	.size	finalize, .-finalize
	.align	2
	.type	error.part.0, @function
error.part.0:
	addi	sp,sp,-32
	sw	s0,24(sp)
	lui	s0,%hi(.LANCHOR0)
	addi	s0,s0,%lo(.LANCHOR0)
	lw	a4,272(s0)
	andi	a1,a1,0xff
	slli	a1,a1,8
	andi	a0,a0,0xff
	or	a5,a0,a1
	li	a0,12
	sh	a5,0(sp)
	sw	ra,28(sp)
	sb	a4,2(sp)
	sb	zero,3(sp)
	sb	zero,4(sp)
	call	mac_step
	li	a3,65536
	li	a5,69
	addi	a3,a3,-1
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a3, a5, a3
# 0 "" 2
 #NO_APP
	sb	a5,8(sp)
	mv	a4,sp
	addi	a5,sp,9
	addi	a1,sp,14
.L159:
	lbu	a2,0(a4)
	sb	a2,0(a5)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a3, a2, a3
# 0 "" 2
 #NO_APP
	addi	a5,a5,1
	addi	a4,a4,1
	bne	a5,a1,.L159
	lw	a5,144(s0)
	lw	a2,184(s0)
	sh	a3,14(sp)
	li	a4,120
	sub	a5,a5,a2
	bgtu	a5,a4,.L164
	addi	a0,sp,8
	call	push8.part.0
	lw	ra,28(sp)
	lw	s0,24(sp)
	lui	a5,%hi(.LANCHOR4+24)
	sw	zero,%lo(.LANCHOR4+24)(a5)
	addi	sp,sp,32
	jr	ra
.L164:
	lw	a5,188(s0)
	lw	ra,28(sp)
	addi	a5,a5,1
	sw	a5,188(s0)
	lw	s0,24(sp)
	lui	a5,%hi(.LANCHOR4+24)
	sw	zero,%lo(.LANCHOR4+24)(a5)
	addi	sp,sp,32
	jr	ra
	.size	error.part.0, .-error.part.0
	.section	.text.startup,"ax",@progbits
	.align	2
	.globl	main
	.type	main, @function
main:
	addi	sp,sp,-160
	sw	s0,152(sp)
	li	a5,-268435456
	sw	ra,156(sp)
	sw	s1,148(sp)
	sw	s2,144(sp)
	sw	s3,140(sp)
	sw	s4,136(sp)
	sw	s5,132(sp)
	sw	s6,128(sp)
	sw	s7,124(sp)
	sw	s8,120(sp)
	sw	s9,116(sp)
	sw	s10,112(sp)
	sw	s11,108(sp)
	li	a3,240
	li	a4,-268435456
	sw	a3,8(a5)
	lw	a5,4(a4)
	lui	s0,%hi(.LANCHOR0)
	andi	a4,a5,1
	bne	a4,zero,.L332
	addi	s0,s0,%lo(.LANCHOR0)
.L166:
	lw	a2,280(s0)
	lw	a3,268(s0)
	andi	a4,a5,14
	srli	a5,a4,3
	or	a5,a5,a2
	lui	a6,%hi(__rom_end)
	andi	a3,a3,112
	addi	s9,a6,%lo(__rom_end)
	slli	a5,a5,7
	li	s10,-4194304
	or	a5,a5,a3
	add	s10,s9,s10
	srai	s10,s10,2
	sw	a4,276(s0)
	sw	a5,268(s0)
	li	a4,-268435456
	sw	a5,0(a4)
	srli	a3,s10,8
	andi	a5,s10,0xff
	sw	a5,32(sp)
	andi	a5,a3,0xff
	sw	a5,36(sp)
	lui	a5,%hi(.LANCHOR4)
	addi	s10,a5,%lo(.LANCHOR4)
	lui	a5,%hi(.L187)
	addi	a5,a5,%lo(.L187)
	sw	a5,40(sp)
	lui	a5,%hi(.LANCHOR0+300)
	addi	a5,a5,%lo(.LANCHOR0+300)
	sw	a5,56(sp)
	lui	a5,%hi(.LANCHOR0+252)
	addi	a5,a5,%lo(.LANCHOR0+252)
	sw	a5,52(sp)
	lui	a5,%hi(.LANCHOR0+168)
	addi	a5,a5,%lo(.LANCHOR0+168)
	sw	a5,48(sp)
	lui	a5,%hi(.LANCHOR0+308)
	addi	a5,a5,%lo(.LANCHOR0+308)
	lui	s6,%hi(.LANCHOR2)
	sw	a5,60(sp)
	lui	s8,%hi(.LANCHOR2-1776)
	addi	a5,s6,%lo(.LANCHOR2)
	sw	a5,4(sp)
	addi	a5,s8,%lo(.LANCHOR2-1776)
	sw	a5,24(sp)
	lui	a5,%hi(.LANCHOR4+12)
	addi	a5,a5,%lo(.LANCHOR4+12)
	li	a2,65536
	sw	a5,44(sp)
	addi	a5,a2,-2
	sw	a5,0(sp)
	li	a5,65536
	li	s11,-251658240
	li	s1,-251658240
	li	s4,-268435456
	lui	s3,%hi(.LANCHOR1)
	addi	a5,a5,-1
	addi	s3,s3,%lo(.LANCHOR1)
	addi	s11,s11,8
	addi	s1,s1,4
	li	s2,63
	sw	a5,28(sp)
	addi	s4,s4,4
.L167:
	lw	a5,0(s11)
	andi	a5,a5,2
	bne	a5,zero,.L168
.L357:
	lw	s8,4(s0)
	lw	s7,0(s0)
.L169:
	lw	a5,284(s0)
	beq	s8,s7,.L171
.L358:
	addi	a3,s8,1
	andi	a4,s8,63
	add	a4,s3,a4
	sw	a3,4(s0)
	sw	zero,288(s0)
	lbu	a4,0(a4)
	beq	a5,zero,.L349
	lw	a3,292(s0)
	li	a2,1
	addi	a0,a3,1
	add	a1,s0,a3
	sw	a0,292(s0)
	sb	a4,300(a1)
	beq	a5,a2,.L350
	li	a2,2
	beq	a5,a2,.L351
	lw	s5,336(s0)
	li	a1,3
	addi	s5,s5,-1
	beq	a5,a1,.L352
	sw	s5,336(s0)
	bne	s5,zero,.L279
	addi	a3,a3,-1
	add	a3,s0,a3
	lbu	a5,301(a3)
	lbu	a3,300(a3)
	lw	a4,296(s0)
	slli	a5,a5,8
	sw	zero,284(s0)
	or	a5,a5,a3
	lbu	a1,300(s0)
	beq	a5,a4,.L183
	lw	a5,272(s0)
	li	a4,254
	bgtu	a5,a4,.L184
	addi	a5,a5,1
	sw	a5,272(s0)
.L184:
	lw	a5,24(s10)
	bne	a5,zero,.L353
.L279:
	lw	a5,0(s4)
	lw	s6,276(s0)
	andi	s5,a5,15
	beq	s6,s5,.L244
	sw	s5,276(s0)
	andi	a5,a5,1
	andi	s6,s6,1
	beq	a5,zero,.L245
	srli	a5,s5,1
	andi	a5,a5,3
	sw	a5,204(s0)
	beq	s6,zero,.L246
	lw	a5,280(s0)
	srli	s5,s5,3
	or	s5,s5,a5
.L247:
	lw	a5,268(s0)
	slli	s5,s5,7
	li	a4,-268435456
	andi	a5,a5,112
	or	a5,a5,s5
	sw	a5,268(s0)
	sw	a5,0(a4)
.L244:
	lw	a5,216(s0)
	beq	a5,zero,.L255
	beq	s8,s7,.L354
.L256:
	lw	a5,32(s10)
	sw	a5,372(s0)
.L255:
	lw	a5,164(s0)
	bne	a5,zero,.L355
.L259:
	lw	a5,348(s0)
	beq	a5,zero,.L348
	beq	s8,s7,.L356
.L348:
	lw	s5,184(s0)
	lw	a5,144(s0)
.L261:
	beq	s5,a5,.L167
	lw	a5,0(s11)
	andi	a5,a5,4
	beq	a5,zero,.L167
	lw	a4,4(sp)
	andi	a5,s5,127
	addi	s5,s5,1
	add	a5,a4,a5
	lbu	a4,-1904(a5)
	sw	s5,184(s0)
	li	a5,-251658240
	sw	a4,0(a5)
	li	a5,3
	sw	a5,0(s11)
	lw	a5,0(s11)
	andi	a5,a5,2
	beq	a5,zero,.L357
.L168:
	lw	a4,0(s1)
	sw	zero,0(s11)
	lw	s7,0(s0)
	lw	s8,4(s0)
	sub	a5,s7,s8
	bgtu	a5,s2,.L170
	andi	a5,s7,63
	add	a5,s3,a5
	addi	s7,s7,1
	sb	a4,0(a5)
	sw	s7,0(s0)
	lw	a5,284(s0)
	bne	s8,s7,.L358
.L171:
	lw	a5,288(s0)
	lw	a4,0(sp)
	bgtu	a5,a4,.L179
	addi	a5,a5,1
	sw	a5,288(s0)
.L179:
	lw	a5,284(s0)
	beq	a5,zero,.L279
	lw	a5,364(s0)
	beq	a5,zero,.L279
	lw	a4,288(s0)
	bne	a5,a4,.L279
	lw	a1,292(s0)
	sw	zero,284(s0)
	beq	a1,zero,.L242
	lbu	a1,300(s0)
.L242:
	lw	a5,272(s0)
	li	a4,254
	bgtu	a5,a4,.L243
	addi	a5,a5,1
	sw	a5,272(s0)
.L243:
	lw	a5,24(s10)
	beq	a5,zero,.L279
	li	a0,5
	call	error.part.0
	j	.L279
.L355:
	li	a0,4
	call	mac_step
	j	.L259
.L170:
	lw	a5,8(s0)
	addi	a5,a5,1
	sw	a5,8(s0)
	j	.L169
.L245:
	lw	a5,280(s0)
	srli	s5,s5,3
	beq	s6,zero,.L347
	lw	a4,32(s10)
	or	s5,s5,a5
	li	a5,1
	sw	a5,216(s0)
	sw	a4,372(s0)
	sw	s5,208(s0)
	j	.L247
.L362:
	lw	s5,8(sp)
	lw	s4,12(sp)
	lw	s0,16(sp)
	lw	s1,20(sp)
.L253:
	lw	a5,280(s0)
	srli	s5,s5,3
	andi	s5,s5,1
	sw	zero,368(s0)
.L347:
	or	s5,s5,a5
	j	.L247
.L356:
	lw	a5,340(s0)
	li	a3,28
	lw	a4,344(s0)
	sub	a2,s9,a5
	ble	a2,a3,.L281
	li	a2,0
	li	a1,64
	li	a0,28
.L270:
	lw	a3,0(a5)
 #APP
# 63 "include/rvbl2.h" 1
	.insn r 0x33, 2, 0x40, a3, a3, a4
# 0 "" 2
 #NO_APP
	lw	a4,4(a5)
 #APP
# 63 "include/rvbl2.h" 1
	.insn r 0x33, 2, 0x40, a4, a4, a3
# 0 "" 2
 #NO_APP
	lw	a3,8(a5)
 #APP
# 63 "include/rvbl2.h" 1
	.insn r 0x33, 2, 0x40, a3, a3, a4
# 0 "" 2
 #NO_APP
	lw	a4,12(a5)
 #APP
# 63 "include/rvbl2.h" 1
	.insn r 0x33, 2, 0x40, a4, a4, a3
# 0 "" 2
 #NO_APP
	lw	a3,16(a5)
 #APP
# 63 "include/rvbl2.h" 1
	.insn r 0x33, 2, 0x40, a3, a3, a4
# 0 "" 2
 #NO_APP
	lw	a4,20(a5)
 #APP
# 63 "include/rvbl2.h" 1
	.insn r 0x33, 2, 0x40, a4, a4, a3
# 0 "" 2
 #NO_APP
	lw	a3,24(a5)
 #APP
# 63 "include/rvbl2.h" 1
	.insn r 0x33, 2, 0x40, a3, a3, a4
# 0 "" 2
 #NO_APP
	lw	a4,28(a5)
 #APP
# 63 "include/rvbl2.h" 1
	.insn r 0x33, 2, 0x40, a4, a4, a3
# 0 "" 2
 #NO_APP
	lw	a3,0(s11)
	addi	a5,a5,32
	addi	a2,a2,8
	andi	a3,a3,2
	beq	a3,zero,.L264
	lw	a7,0(s1)
	sw	zero,0(s11)
	lw	a3,0(s0)
	lw	a6,4(s0)
	sub	a6,a3,a6
	bgtu	a6,s2,.L265
	andi	a6,a3,63
	add	a6,s3,a6
	addi	a3,a3,1
	sw	a3,0(s0)
	sb	a7,0(a6)
.L264:
	beq	a2,a1,.L267
	sub	a3,s9,a5
	bgt	a3,a0,.L270
	mv	a3,a5
.L263:
	beq	a5,s9,.L344
	neg	a2,a2
	slli	a2,a2,2
	addi	a2,a2,256
	add	a5,a5,a2
	j	.L271
.L359:
	beq	a3,s9,.L344
.L271:
	lw	a2,0(a3)
	addi	a3,a3,4
 #APP
# 63 "include/rvbl2.h" 1
	.insn r 0x33, 2, 0x40, a4, a2, a4
# 0 "" 2
 #NO_APP
	bne	a5,a3,.L359
.L267:
	sw	a5,340(s0)
	sw	a4,344(s0)
	bne	a5,s9,.L348
.L273:
	li	a3,3
	sb	a3,72(sp)
	lw	a3,32(sp)
	srli	a5,a4,8
	li	a0,12
	sb	a3,73(sp)
	lw	a3,36(sp)
	sb	a4,75(sp)
	sb	a5,76(sp)
	sb	a3,74(sp)
	sw	zero,348(s0)
	call	mac_step
	li	a5,73
	lw	a4,28(sp)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a2, a5, a4
# 0 "" 2
 #NO_APP
	sb	a5,80(sp)
	addi	a4,sp,72
	addi	a5,sp,81
.L274:
	lbu	a3,0(a4)
	sb	a3,0(a5)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a2, a3, a2
# 0 "" 2
 #NO_APP
	addi	a5,a5,1
	addi	a3,sp,86
	addi	a4,a4,1
	bne	a3,a5,.L274
	lw	a5,144(s0)
	lw	s5,184(s0)
	sh	a2,86(sp)
	li	a4,120
	sub	a3,a5,s5
	bgtu	a3,a4,.L360
	addi	a0,sp,80
	call	push8.part.0
	lw	a5,144(s0)
	j	.L261
.L265:
	lw	a3,8(s0)
	addi	a3,a3,1
	sw	a3,8(s0)
	j	.L264
.L354:
	lw	a5,284(s0)
	bne	a5,zero,.L256
	lw	a5,372(s0)
	addi	a5,a5,-1
	sw	a5,372(s0)
	bne	a5,zero,.L255
	call	finalize
	j	.L255
.L349:
	li	a5,165
	bne	a4,a5,.L279
	li	a5,1
	sw	a5,284(s0)
	lw	a5,28(sp)
	sw	zero,292(s0)
	sw	a5,296(s0)
	j	.L279
.L246:
	lw	a5,216(s0)
	bne	a5,zero,.L361
.L249:
	lw	a4,368(s0)
	li	a5,1
	sw	a5,212(s0)
	sw	zero,140(s0)
	beq	a4,zero,.L253
	lw	a2,220(s0)
	lw	a3,28(s10)
	lw	a0,24(sp)
	sw	s5,8(sp)
	sw	s4,12(sp)
	sw	s0,16(sp)
	sw	s1,20(sp)
	mv	s0,s6
	mv	s5,a3
	mv	s4,a2
	mv	s6,a0
	mv	s1,a4
	j	.L252
.L251:
	addi	s0,s0,1
	addi	s6,s6,20
	beq	s0,s1,.L362
.L252:
	lw	a5,12(s6)
	sub	a5,s4,a5
	bgtu	a5,s5,.L251
	lbu	a1,16(s6)
	mv	a0,s6
	call	vt_add
	j	.L251
.L350:
	lw	a5,296(s0)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a4, a4, a5
# 0 "" 2
 #NO_APP
	li	a5,2
	sw	a4,296(s0)
	sw	a5,284(s0)
	j	.L279
.L351:
	li	a5,32
	bgtu	a4,a5,.L363
	lw	a3,296(s0)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a3, a4, a3
# 0 "" 2
 #NO_APP
	seqz	a5,a4
	addi	a5,a5,3
	addi	a4,a4,2
	sw	a3,296(s0)
	sw	a4,336(s0)
	sw	a5,284(s0)
	j	.L279
.L352:
	lw	a5,296(s0)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a4, a4, a5
# 0 "" 2
 #NO_APP
	sw	a4,296(s0)
	sw	s5,336(s0)
	bne	s5,a2,.L279
	li	a5,4
	sw	a5,284(s0)
	j	.L279
.L361:
	call	finalize
	lw	s5,276(s0)
	j	.L249
.L344:
	sw	s9,340(s0)
	sw	a4,344(s0)
	j	.L273
.L363:
	lw	a5,272(s0)
	sw	zero,284(s0)
	li	a4,254
	lbu	a1,300(s0)
	bgtu	a5,a4,.L178
	addi	a5,a5,1
	sw	a5,272(s0)
.L178:
	lw	a5,24(s10)
	beq	a5,zero,.L279
	li	a0,2
	call	error.part.0
	j	.L179
.L183:
	addi	a5,a1,-67
	andi	a5,a5,0xff
	li	a3,37
	lbu	a4,301(s0)
	bgtu	a5,a3,.L185
	lw	a3,40(sp)
	slli	a5,a5,2
	add	a5,a3,a5
	lw	a5,0(a5)
	jr	a5
	.section	.rodata
	.align	2
	.align	2
.L187:
	.word	.L197
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L196
	.word	.L195
	.word	.L194
	.word	.L185
	.word	.L193
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L192
	.word	.L191
	.word	.L190
	.word	.L189
	.word	.L188
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L185
	.word	.L186
	.section	.text.startup
.L360:
	lw	a4,188(s0)
	addi	a4,a4,1
	sw	a4,188(s0)
	j	.L261
.L281:
	mv	a3,a5
	li	a2,0
	j	.L263
.L353:
	li	a0,1
	call	error.part.0
	j	.L179
.L332:
	srli	a4,a5,1
	addi	s0,s0,%lo(.LANCHOR0)
	andi	a4,a4,3
	sw	a4,204(s0)
	j	.L166
.L185:
	lw	a5,272(s0)
	li	a4,254
	bgtu	a5,a4,.L220
	addi	a5,a5,1
	sw	a5,272(s0)
.L220:
	lw	a5,24(s10)
	beq	a5,zero,.L179
	li	a0,3
	call	error.part.0
	j	.L179
.L186:
	li	a5,12
	bne	a4,a5,.L198
	addi	a0,sp,80
	li	a5,1
	addi	a1,s0,302
	sw	a5,24(s10)
	call	get_epc
	addi	a0,sp,80
	call	hot_find
	blt	a0,zero,.L179
	lw	a4,356(s0)
	add	a5,s0,a0
	li	a3,2
	addi	a4,a4,-1
	sb	a3,12(a5)
	sw	a4,356(s0)
	j	.L179
.L189:
	li	a5,17
	bne	a4,a5,.L198
	addi	a1,s0,302
	addi	a0,sp,80
	li	a5,1
	sw	a5,24(s10)
	call	get_epc
	lbu	a4,316(s0)
	lbu	a3,315(s0)
	lbu	a5,317(s0)
	lbu	a2,318(s0)
	lbu	a1,314(s0)
	slli	a4,a4,8
	or	a4,a4,a3
	slli	a5,a5,16
	or	a5,a5,a4
	slli	a2,a2,24
	or	a2,a2,a5
	andi	a1,a1,7
	addi	a0,sp,80
	call	seen_put
	j	.L179
.L188:
	li	a5,4
	bne	a4,a5,.L198
	lhu	a5,304(s0)
	lhu	a3,302(s0)
	lw	a4,220(s0)
	slli	a5,a5,16
	li	a2,1
	sw	a2,24(s10)
	or	a5,a5,a3
	bleu	a5,a4,.L179
	sw	a5,220(s0)
	j	.L179
.L197:
	li	a5,14
	bne	a4,a5,.L198
	lbu	a5,302(s0)
	lbu	a4,303(s0)
	li	a3,1
	andi	a5,a5,7
	sw	a5,0(s10)
	lw	a5,56(sp)
	andi	a4,a4,1
	sw	a3,24(s10)
	sw	a4,280(s0)
	li	a1,12
.L217:
	lw	a3,44(sp)
	lhu	a2,4(a5)
	addi	a5,a5,2
	add	a3,a3,s5
	sh	a2,0(a3)
	addi	s5,s5,2
	bne	s5,a1,.L217
	lw	a5,276(s0)
	lw	a3,268(s0)
	srli	a5,a5,3
	andi	a5,a5,1
	or	a5,a5,a4
	slli	a5,a5,7
	andi	a4,a3,112
	or	a5,a5,a4
	sw	a5,268(s0)
	li	a4,-268435456
	sw	a5,0(a4)
	j	.L179
.L196:
	li	a5,3
	bne	a4,a5,.L198
	lbu	a5,302(s0)
	lbu	a4,304(s0)
	lbu	a3,303(s0)
	andi	a5,a5,7
	slli	a5,a5,1
	slli	a4,a4,8
	or	a4,a4,a3
	add	a5,s0,a5
	li	a3,1
	sw	a3,24(s10)
	sh	a4,224(a5)
	j	.L179
.L195:
	li	a5,13
	bne	a4,a5,.L198
	addi	a0,sp,80
	li	a5,1
	addi	a1,s0,302
	sw	a5,24(s10)
	call	get_epc
	addi	a0,sp,80
	call	hot_find
	bge	a0,zero,.L179
	lw	a0,84(sp)
	li	a3,-2048143360
	addi	a3,a3,-1417
	lw	a5,80(sp)
	mul	a0,a0,a3
	li	a4,-1640529920
	lw	a3,88(sp)
	addi	a4,a4,-1615
	li	t3,-1028476928
	addi	t3,t3,-451
	li	a2,-251658240
	li	a6,-251658240
	addi	a2,a2,8
	addi	a6,a6,4
	mul	a5,a5,a4
	li	a4,668266496
	addi	a4,a4,-1233
	li	a7,63
	li	a1,1
	li	t1,8
	mul	a3,a3,t3
	xor	a5,a5,a0
	xor	a5,a5,a3
	mul	a5,a5,a4
	srli	a5,a5,26
	j	.L237
.L365:
	andi	a0,a3,63
	add	a0,s3,a0
	addi	a3,a3,1
	sw	a3,0(s0)
	sb	t3,0(a0)
.L234:
	add	a0,s0,a4
	lbu	a3,12(a0)
	bne	a3,a1,.L364
	addi	s5,s5,1
	beq	s5,t1,.L179
.L237:
	lw	a3,0(a2)
	add	a4,s5,a5
	andi	a4,a4,63
	andi	a3,a3,2
	beq	a3,zero,.L234
	lw	t3,0(a6)
	sw	zero,0(a2)
	lw	a3,0(s0)
	lw	a0,4(s0)
	sub	a0,a3,a0
	bleu	a0,a7,.L365
	lw	a3,8(s0)
	addi	a3,a3,1
	sw	a3,8(s0)
	j	.L234
.L194:
	bne	a4,zero,.L198
	li	a5,4194304
	sw	a5,340(s0)
	li	a5,65536
	li	a4,1
	addi	a5,a5,-1
	sw	a4,24(s10)
	sw	a5,344(s0)
	sw	a4,348(s0)
	j	.L179
.L193:
	li	a5,16
	beq	a4,a5,.L208
	beq	a4,zero,.L209
.L198:
	lw	a5,272(s0)
	li	a4,254
	bgtu	a5,a4,.L223
	addi	a5,a5,1
	sw	a5,272(s0)
.L223:
	lw	a5,24(s10)
	beq	a5,zero,.L179
	li	a0,4
	call	error.part.0
	j	.L179
.L192:
	li	a5,10
	bne	a4,a5,.L198
	lbu	a3,304(s0)
	lbu	a4,306(s0)
	lbu	a5,308(s0)
	lbu	a0,307(s0)
	lbu	a7,303(s0)
	lbu	a6,305(s0)
	lbu	a1,302(s0)
	lbu	a2,309(s0)
	slli	a3,a3,8
	slli	a4,a4,8
	slli	a5,a5,8
	or	a5,a5,a0
	or	a3,a3,a7
	or	a4,a4,a6
	li	a0,1
	sw	a5,8(s10)
	sw	a0,24(s10)
	lui	a5,%hi(.LANCHOR4)
	sw	a3,28(s10)
	sw	a4,4(s10)
	sw	a1,360(s0)
	addi	s10,a5,%lo(.LANCHOR4)
	andi	a5,a2,0xff
	beq	a2,zero,.L366
.L215:
	lhu	a4,310(s0)
	sw	a5,32(s10)
	sw	a4,364(s0)
	j	.L179
.L191:
	bne	a4,zero,.L198
	lbu	a3,352(s0)
	lhu	a5,240(s0)
	lbu	a4,272(s0)
	lw	a2,356(s0)
	slli	a3,a3,16
	or	a5,a5,a3
	slli	a4,a4,24
	or	a5,a5,a4
	li	a0,12
	li	a4,1
	sw	a5,72(sp)
	sw	a4,24(s10)
	sb	a2,76(sp)
	call	mac_step
	li	a5,65536
	li	a3,81
	addi	a5,a5,-1
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a5, a3, a5
# 0 "" 2
 #NO_APP
	li	a4,0
	sb	a3,80(sp)
	li	a0,5
	addi	a3,sp,72
.L211:
	lbu	a2,0(a3)
	addi	a4,a4,1
	addi	a1,sp,80
	add	a1,a1,a4
	sb	a2,0(a1)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a5, a2, a5
# 0 "" 2
 #NO_APP
	addi	a3,a3,1
	bne	a4,a0,.L211
	lw	a4,144(s0)
	lw	a2,184(s0)
	sh	a5,86(sp)
	li	a3,120
	sub	a5,a4,a2
	bgtu	a5,a3,.L367
	addi	a0,sp,80
	call	push8.part.0
	j	.L179
.L190:
	li	a5,21
	bne	a4,a5,.L198
	lhu	s5,304(s0)
	lhu	a5,302(s0)
	lw	a4,220(s0)
	slli	s5,s5,16
	li	a3,1
	or	s5,s5,a5
	sw	a3,24(s10)
	lhu	a5,306(s0)
	lhu	a1,320(s0)
	lbu	s6,322(s0)
	bgtu	s5,a4,.L218
.L219:
	li	a3,65536
	srli	a4,a5,8
	addi	a3,a3,-1
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a4, a4, a3
# 0 "" 2
 #NO_APP
	andi	a5,a5,0xff
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a4, a5, a4
# 0 "" 2
 #NO_APP
	addi	a5,s0,308
	addi	a2,s0,320
.L224:
	lbu	a3,0(a5)
 #APP
# 51 "include/rvbl2.h" 1
	.insn r 0x33, 0, 0x40, a4, a3, a4
# 0 "" 2
 #NO_APP
	addi	a5,a5,1
	bne	a2,a5,.L224
	li	a5,-251658240
	lw	a3,8(a5)
	addi	a5,a5,8
	andi	a3,a3,2
	beq	a3,zero,.L225
	li	a2,-251658240
	lw	a0,4(a2)
	sw	zero,0(a5)
	lw	a5,0(s0)
	lw	a3,4(s0)
	li	a6,63
	sub	a3,a5,a3
	bgtu	a3,a6,.L226
	andi	a3,a5,63
	add	a3,s3,a3
	addi	a5,a5,1
	sw	a5,0(s0)
	sb	a0,0(a3)
.L225:
	li	a5,65536
	addi	a5,a5,-1
	xor	a4,a4,a5
	bne	a1,a4,.L368
	lw	a5,360(s0)
	bltu	s6,a5,.L179
	lw	a1,60(sp)
	addi	a0,sp,80
	call	get_epc
	lw	a5,212(s0)
	bne	a5,zero,.L369
	li	a5,-251658240
	lw	a4,8(a5)
	addi	a5,a5,8
	andi	a4,a4,2
	beq	a4,zero,.L230
	li	a3,-251658240
	lw	a2,4(a3)
	sw	zero,0(a5)
	lw	a5,0(s0)
	lw	a4,4(s0)
	li	a1,63
	sub	a4,a5,a4
	bgtu	a4,a1,.L231
	andi	a4,a5,63
	add	a4,s3,a4
	addi	a5,a5,1
	sw	a5,0(s0)
	sb	a2,0(a4)
.L230:
	lw	a4,368(s0)
	li	a5,8
	beq	a4,a5,.L370
.L232:
	lw	a4,368(s0)
	lw	a3,4(sp)
	slli	a5,a4,2
	add	a5,a5,a4
	slli	a5,a5,2
	add	a5,a3,a5
	lw	a3,80(sp)
	addi	a4,a4,1
	sw	s5,-1764(a5)
	sw	a3,-1776(a5)
	lw	a3,84(sp)
	sb	s6,-1760(a5)
	sw	a4,368(s0)
	sw	a3,-1772(a5)
	lw	a3,88(sp)
	sw	a3,-1768(a5)
	j	.L179
.L368:
	lw	a5,352(s0)
	li	a4,254
	bgtu	a5,a4,.L179
	addi	a5,a5,1
	sw	a5,352(s0)
	j	.L179
.L218:
	sw	s5,220(s0)
	j	.L219
.L209:
	li	a5,1
	li	a0,12
	sw	a5,24(s10)
	call	mac_step
	sw	zero,248(s0)
	sw	zero,200(s0)
	j	.L179
.L366:
	li	a5,1
	j	.L215
.L208:
	li	s5,1
	li	a0,12
	sw	s5,24(s10)
	call	mac_step
	lhu	a4,312(s0)
	lhu	a5,316(s0)
	lhu	a1,310(s0)
	lhu	a2,314(s0)
	lhu	a6,304(s0)
	lhu	a3,308(s0)
	lhu	a0,306(s0)
	lhu	a7,302(s0)
	slli	a4,a4,16
	slli	a5,a5,16
	or	a4,a4,a1
	or	a5,a5,a2
	lw	a1,48(sp)
	lw	a2,52(sp)
	slli	a6,a6,16
	slli	a3,a3,16
	or	a3,a3,a0
	or	a6,a6,a7
	addi	a0,sp,80
	sw	s5,248(s0)
	sw	zero,200(s0)
	sw	a6,252(s0)
	sw	a3,256(s0)
	sw	a4,260(s0)
	sw	a5,264(s0)
	call	chaskey12_subkeys
	j	.L179
.L226:
	lw	a5,8(s0)
	addi	a5,a5,1
	sw	a5,8(s0)
	j	.L225
.L367:
	lw	a5,188(s0)
	addi	a5,a5,1
	sw	a5,188(s0)
	j	.L179
.L364:
	lw	a3,356(s0)
	slli	a5,a4,1
	add	a5,a5,a4
	addi	a4,a3,1
	lw	a3,80(sp)
	slli	a5,a5,2
	add	a5,s3,a5
	sw	a3,64(a5)
	lw	a3,84(sp)
	sb	a1,12(a0)
	sw	a4,356(s0)
	sw	a3,68(a5)
	lw	a3,88(sp)
	sw	a3,72(a5)
	j	.L179
.L369:
	mv	a1,s6
	addi	a0,sp,80
	call	vt_add
	j	.L179
.L231:
	lw	a5,8(s0)
	addi	a5,a5,1
	sw	a5,8(s0)
	j	.L230
.L370:
	lw	a4,4(sp)
	lw	a5,24(sp)
	addi	a4,a4,-1636
.L233:
	lw	a6,20(a5)
	lw	a0,24(a5)
	lw	a1,28(a5)
	lw	a2,32(a5)
	lw	a3,36(a5)
	sw	a6,0(a5)
	sw	a0,4(a5)
	sw	a1,8(a5)
	sw	a2,12(a5)
	sw	a3,16(a5)
	addi	a5,a5,20
	bne	a4,a5,.L233
	li	a5,7
	sw	a5,368(s0)
	j	.L232
	.size	main, .-main
	.data
	.align	2
	.set	.LANCHOR4,. + 0
	.type	gantry, @object
	.size	gantry, 4
gantry:
	.word	1
	.type	dedup_ms, @object
	.size	dedup_ms, 4
dedup_ms:
	.word	3000
	.type	vmax_kmh, @object
	.size	vmax_kmh, 4
vmax_kmh:
	.word	250
	.type	fares, @object
	.size	fares, 12
fares:
	.half	0
	.half	250
	.half	500
	.half	750
	.half	130
	.half	380
	.type	err_armed, @object
	.size	err_armed, 4
err_armed:
	.word	1
	.type	guard_ms, @object
	.size	guard_ms, 4
guard_ms:
	.word	500
	.type	hold, @object
	.size	hold, 4
hold:
	.word	64
	.bss
	.align	2
	.set	.LANCHOR0,. + 0
	.type	rxt, @object
	.size	rxt, 4
rxt:
	.zero	4
	.type	rxh, @object
	.size	rxh, 4
rxh:
	.zero	4
	.type	rx_lost, @object
	.size	rx_lost, 4
rx_lost:
	.zero	4
	.type	hot_state, @object
	.size	hot_state, 64
hot_state:
	.zero	64
	.type	seen_used, @object
	.size	seen_used, 64
seen_used:
	.zero	64
	.type	vt_n, @object
	.size	vt_n, 4
vt_n:
	.zero	4
	.type	txt, @object
	.size	txt, 4
txt:
	.zero	4
	.type	mv, @object
	.size	mv, 16
mv:
	.zero	16
	.type	mac_r, @object
	.size	mac_r, 4
mac_r:
	.zero	4
	.type	k2, @object
	.size	k2, 16
k2:
	.zero	16
	.type	txh, @object
	.size	txh, 4
txh:
	.zero	4
	.type	tx_drops, @object
	.size	tx_drops, 4
tx_drops:
	.zero	4
	.type	mac_rec, @object
	.size	mac_rec, 8
mac_rec:
	.zero	8
	.type	auth_ctr, @object
	.size	auth_ctr, 4
auth_ctr:
	.zero	4
	.type	code, @object
	.size	code, 4
code:
	.zero	4
	.type	fin_closed, @object
	.size	fin_closed, 4
fin_closed:
	.zero	4
	.type	active, @object
	.size	active, 4
active:
	.zero	4
	.type	fin_pending, @object
	.size	fin_pending, 4
fin_pending:
	.zero	4
	.type	now, @object
	.size	now, 4
now:
	.zero	4
	.type	pos, @object
	.size	pos, 16
pos:
	.zero	16
	.type	vehicles, @object
	.size	vehicles, 4
vehicles:
	.zero	4
	.type	seq, @object
	.size	seq, 4
seq:
	.zero	4
	.type	auth_on, @object
	.size	auth_on, 4
auth_on:
	.zero	4
	.type	kk, @object
	.size	kk, 16
kk:
	.zero	16
	.type	pins, @object
	.size	pins, 4
pins:
	.zero	4
	.type	bad_frame, @object
	.size	bad_frame, 4
bad_frame:
	.zero	4
	.type	gp, @object
	.size	gp, 4
gp:
	.zero	4
	.type	closed_cfg, @object
	.size	closed_cfg, 4
closed_cfg:
	.zero	4
	.type	pst, @object
	.size	pst, 4
pst:
	.zero	4
	.type	idle, @object
	.size	idle, 4
idle:
	.zero	4
	.type	plen, @object
	.size	plen, 4
plen:
	.zero	4
	.type	pcrc, @object
	.size	pcrc, 4
pcrc:
	.zero	4
	.type	buf, @object
	.size	buf, 36
buf:
	.zero	36
	.type	need, @object
	.size	need, 4
need:
	.zero	4
	.type	att_p, @object
	.size	att_p, 4
att_p:
	.zero	4
	.type	att_crc, @object
	.size	att_crc, 4
att_crc:
	.zero	4
	.type	att_busy, @object
	.size	att_busy, 4
att_busy:
	.zero	4
	.type	bad_tag, @object
	.size	bad_tag, 4
bad_tag:
	.zero	4
	.type	hot_n, @object
	.size	hot_n, 4
hot_n:
	.zero	4
	.type	rssi_min, @object
	.size	rssi_min, 4
rssi_min:
	.zero	4
	.type	frame_timeout, @object
	.size	frame_timeout, 4
frame_timeout:
	.zero	4
	.type	pend_n, @object
	.size	pend_n, 4
pend_n:
	.zero	4
	.type	fin_hold, @object
	.size	fin_hold, 4
fin_hold:
	.zero	4
	.section	.rodata
	.align	2
	.set	.LANCHOR3,. + 0
	.type	code_to_class, @object
	.size	code_to_class, 4
code_to_class:
	.string	"\001\002\003"
	.section	.noinit,"aw"
	.align	2
	.set	.LANCHOR1,. + 0
	.set	.LANCHOR2,. + 4096
	.type	rxq, @object
	.size	rxq, 64
rxq:
	.zero	64
	.type	hot, @object
	.size	hot, 768
hot:
	.zero	768
	.type	seen, @object
	.size	seen, 1280
seen:
	.zero	1280
	.type	vt, @object
	.size	vt, 80
vt:
	.zero	80
	.type	txq, @object
	.size	txq, 128
txq:
	.zero	128
	.type	pend, @object
	.size	pend, 160
pend:
	.zero	160
	.ident	"GCC: (xPack GNU RISC-V Embedded GCC x86_64) 13.2.0"
