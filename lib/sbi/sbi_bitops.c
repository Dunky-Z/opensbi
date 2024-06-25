/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2020 Western Digital Corporation or its affiliates.
 *
 * Authors:
 *   Atish Patra <atish.patra@wdc.com>
 *   Anup Patel <anup.patel@wdc.com>
 */

#include <sbi/sbi_bitops.h>

#define BITOP_WORD(nr)		((nr) / BITS_PER_LONG)

/**
 * find_first_bit - find the first set bit in a memory region
 * @addr: The address to start the search at
 * @size: The maximum size to search
 *
 * Returns the bit number of the first set bit.
 */
/**
 * find_first_bit - 在内存区域中查找第一个设置的位
 * @addr: 开始搜索的地址
 * @size: 最大搜索范围
 *
 * 返回第一个设置位的位数。
 */
unsigned long find_first_bit(const unsigned long *addr,
			     unsigned long size)
{
	const unsigned long *p = addr;   // 指向要搜索的地址
	unsigned long result = 0;        // 存储结果的变量
	unsigned long tmp;               // 临时变量

	while (size & ~(BITS_PER_LONG-1)) {
		if ((tmp = *(p++)))         // 如果当前位置的值不为0，则找到第一个设置的位
			goto found;
		result += BITS_PER_LONG;    // 更新结果位置，跳过一个完整的长整型
		size -= BITS_PER_LONG;      // 更新剩余的搜索范围
	}
	if (!size)
		return result;              // 如果没有剩余的搜索范围，则直接返回结果

	tmp = (*p) & (~0UL >> (BITS_PER_LONG - size));  // 获取剩余范围内的位并清除超出部分
	if (tmp == 0UL)                 // 检查剩余范围内是否有设置的位
		return result + size;       // 如果没有设置的位，则返回结果加上剩余的搜索范围
found:
	return result + sbi_ffs(tmp);   // 返回结果加上从tmp中找到的第一个设置的位的位数
}


/**
 * find_first_zero_bit - find the first cleared bit in a memory region
 * @addr: The address to start the search at
 * @size: The maximum size to search
 *
 * Returns the bit number of the first cleared bit.
 */
unsigned long find_first_zero_bit(const unsigned long *addr,
				  unsigned long size)
{
	const unsigned long *p = addr;
	unsigned long result = 0;
	unsigned long tmp;

	while (size & ~(BITS_PER_LONG-1)) {
		if (~(tmp = *(p++)))
			goto found;
		result += BITS_PER_LONG;
		size -= BITS_PER_LONG;
	}
	if (!size)
		return result;

	tmp = (*p) | (~0UL << size);
	if (tmp == ~0UL)	/* Are any bits zero? */
		return result + size;	/* Nope. */
found:
	return result + sbi_ffz(tmp);
}

/**
 * find_last_bit - find the last set bit in a memory region
 * @addr: The address to start the search at
 * @size: The maximum size to search
 *
 * Returns the bit number of the first set bit, or size.
 */
unsigned long find_last_bit(const unsigned long *addr,
			    unsigned long size)
{
	unsigned long words;
	unsigned long tmp;

	/* Start at final word. */
	words = size / BITS_PER_LONG;

	/* Partial final word? */
	if (size & (BITS_PER_LONG-1)) {
		tmp = (addr[words] & (~0UL >> (BITS_PER_LONG
					 - (size & (BITS_PER_LONG-1)))));
		if (tmp)
			goto found;
	}

	while (words) {
		tmp = addr[--words];
		if (tmp) {
found:
			return words * BITS_PER_LONG + sbi_fls(tmp);
		}
	}

	/* Not found */
	return size;
}

/**
 * find_next_bit - find the next set bit in a memory region
 * @addr: The address to base the search on
 * @offset: The bitnumber to start searching at
 * @size: The bitmap size in bits
 */
unsigned long find_next_bit(const unsigned long *addr,
			    unsigned long size, unsigned long offset)
{
	const unsigned long *p = addr + BITOP_WORD(offset);
	unsigned long result = offset & ~(BITS_PER_LONG-1);
	unsigned long tmp;

	if (offset >= size)
		return size;
	size -= result;
	offset %= BITS_PER_LONG;
	if (offset) {
		tmp = *(p++);
		tmp &= (~0UL << offset);
		if (size < BITS_PER_LONG)
			goto found_first;
		if (tmp)
			goto found_middle;
		size -= BITS_PER_LONG;
		result += BITS_PER_LONG;
	}
	while (size & ~(BITS_PER_LONG-1)) {
		if ((tmp = *(p++)))
			goto found_middle;
		result += BITS_PER_LONG;
		size -= BITS_PER_LONG;
	}
	if (!size)
		return result;
	tmp = *p;

found_first:
	tmp &= (~0UL >> (BITS_PER_LONG - size));
	if (tmp == 0UL)		/* Are any bits set? */
		return result + size;	/* Nope. */
found_middle:
	return result + sbi_ffs(tmp);
}

/**
 * find_next_zero_bit - find the next cleared bit in a memory region
 * @addr: The address to base the search on
 * @offset: The bitnumber to start searching at
 * @size: The bitmap size in bits
 */
/**
 * find_next_zero_bit - 在内存区域中找到下一个被清除的位
 * @addr: 搜索的基地址
 * @offset: 开始搜索的位号
 * @size: 位图的大小（以位为单位）
 */
unsigned long find_next_zero_bit(const unsigned long *addr,
				 unsigned long size,
				 unsigned long offset)
{
	const unsigned long *p = addr + BITOP_WORD(offset); // 指向包含给定偏移位的字
	unsigned long result = offset & ~(BITS_PER_LONG-1); // 计算字对齐的偏移量
	unsigned long tmp;

	if (offset >= size) // 如果偏移量超出位图大小
		return size; // 返回大小，因为没有要找的0位
	size -= result; // 调整大小以考虑偏移量
	offset %= BITS_PER_LONG; // 计算字内的位偏移
	if (offset) { // 如果有字内的位偏移
		tmp = *(p++); // 读取当前字并推进指针
		tmp |= ~0UL >> (BITS_PER_LONG - offset); // 屏蔽偏移量之前的位
		if (size < BITS_PER_LONG) // 如果剩余大小小于一个完整的字
			goto found_first; // 跳转到 found_first 处理部分字
		if (~tmp) // 如果当前字中有0位
			goto found_middle; // 跳转到 found_middle 找到第一个0位
		size -= BITS_PER_LONG; // 将大小减少一个完整的字
		result += BITS_PER_LONG; // 将结果增加一个完整的字
	}
	while (size & ~(BITS_PER_LONG-1)) { // 当有完整的字要处理时
		if (~(tmp = *(p++))) // 读取下一个字并检查是否有0位
			goto found_middle; // 如果找到0位则跳转到 found_middle
		result += BITS_PER_LONG; // 将结果增加一个完整的字
		size -= BITS_PER_LONG; // 将大小减少一个完整的字
	}
	if (!size) // 如果没有更多的位要处理
		return result; // 返回结果，因为没有找到0位
	tmp = *p; // 读取剩余的位

found_first:
	tmp |= ~0UL << size; // 屏蔽超出剩余大小的位
	if (tmp == ~0UL)	/* 是否有任何位为0？ */
		return result + size;	/* 否。 */
found_middle:
	return result + sbi_ffz(tmp); // 返回找到的第一个0位的位置
}
