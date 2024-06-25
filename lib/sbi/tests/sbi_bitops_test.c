/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Author: Dongdong Zhang <zhangdongdong@eswincomputing.com>
 */

#include "sbi/sbi_console.h"
#include <sbi/sbi_bitops.h>
#include <sbi/sbi_unit_test.h>

static unsigned long test_data1 = 0xDEADBEEF;
static unsigned long test_data2 = 0x0;
static unsigned long test_data3 = 0xFFFFFFFF;
static unsigned long test_data4 = 0x8000000000000000;

unsigned long bits_to_search = sizeof(test_data1) * 8;

// 找到第一个1的位置
static void find_first_bit_test(struct sbiunit_test_case *test)
{
	sbi_printf("find_first_bit = %lu \n",
		   find_first_bit(&test_data1, bits_to_search));
	SBIUNIT_EXPECT_EQ(test, find_first_bit(&test_data1, bits_to_search), 0);
	sbi_printf("find_first_bit = %lu \n",
		   find_first_bit(&test_data2, bits_to_search));
	SBIUNIT_EXPECT_EQ(test, find_first_bit(&test_data2, bits_to_search),
			  64);
	sbi_printf("find_first_bit = %lu \n",
		   find_first_bit(&test_data3, bits_to_search));
	SBIUNIT_EXPECT_EQ(test, find_first_bit(&test_data3, bits_to_search), 0);
	sbi_printf("find_first_bit = %lu \n",
		   find_first_bit(&test_data4, bits_to_search));
	SBIUNIT_EXPECT_EQ(test, find_first_bit(&test_data4, bits_to_search),
			  63);
}

static void find_first_zero_bit_test(struct sbiunit_test_case *test)
{
	sbi_printf("find_first_zero_bit = %lu \n",
		   find_first_zero_bit(&test_data1, bits_to_search));
	SBIUNIT_EXPECT_EQ(test,
			  find_first_zero_bit(&test_data1, bits_to_search), 4);
	sbi_printf("find_first_zero_bit = %lu \n",
		   find_first_zero_bit(&test_data2, bits_to_search));
	SBIUNIT_EXPECT_EQ(test,
			  find_first_zero_bit(&test_data2, bits_to_search), 0);
	sbi_printf("find_first_zero_bit = %lu \n",
		   find_first_zero_bit(&test_data3, bits_to_search));
	SBIUNIT_EXPECT_EQ(test,
			  find_first_zero_bit(&test_data3, bits_to_search), 32);
	sbi_printf("find_first_zero_bit = %lu \n",
		   find_first_zero_bit(&test_data4, bits_to_search));
	SBIUNIT_EXPECT_EQ(test,
			  find_first_zero_bit(&test_data4, bits_to_search), 0);
}

static void find_last_bit_test(struct sbiunit_test_case *test)
{
	sbi_printf("find_last_bit = %lu \n",
		   find_last_bit(&test_data1, bits_to_search));
	SBIUNIT_EXPECT_EQ(test, find_last_bit(&test_data1, bits_to_search), 31);
	sbi_printf("find_last_bit = %lu \n",
		   find_last_bit(&test_data2, bits_to_search));
	SBIUNIT_EXPECT_EQ(test, find_last_bit(&test_data2, bits_to_search), 64);
	sbi_printf("find_last_bit = %lu \n",
		   find_last_bit(&test_data3, bits_to_search));
	SBIUNIT_EXPECT_EQ(test, find_last_bit(&test_data3, bits_to_search), 31);
}

static unsigned long fnb_1 = 0xDEADBEEF;
static unsigned long fnb_2 = 0x0;
static unsigned long fnb_3 = 0xFFFFFFFF;
static unsigned long fnb_4 = 0x8000000000000000;

static void find_next_bit_test(struct sbiunit_test_case *test)
{
	// 普通数据，offset等于0
	sbi_printf("find_next_bit = %lu \n",
		   find_next_bit(&fnb_1, bits_to_search, 0));
	SBIUNIT_EXPECT_EQ(test, find_next_bit(&fnb_1, bits_to_search, 0), 0);
	// 普通数据，offset不为0
	sbi_printf("find_next_bit = %lu \n",
		   find_next_bit(&fnb_1, bits_to_search, 4));
	SBIUNIT_EXPECT_EQ(test, find_next_bit(&fnb_1, bits_to_search, 4), 5);
	// 全为0的数据，offset为0
	sbi_printf("find_next_bit = %lu \n",
		   find_next_bit(&fnb_2, bits_to_search, 0));
	SBIUNIT_EXPECT_EQ(test, find_next_bit(&fnb_2, bits_to_search, 0), 64);
	// 全为1的数据，offset为0
	sbi_printf("find_next_bit = %lu \n",
		   find_next_bit(&fnb_3, bits_to_search, 0));
	SBIUNIT_EXPECT_EQ(test, find_next_bit(&fnb_3, bits_to_search, 0), 0);
	// 64位数，offset为0
	sbi_printf("find_next_bit = %lu \n",
		   find_next_bit(&fnb_4, bits_to_search, 0));
	SBIUNIT_EXPECT_EQ(test, find_next_bit(&fnb_4, bits_to_search, 0), 63);
}

static void find_next_zero_bit_test(struct sbiunit_test_case *test)
{
	sbi_printf("find_next_zero_bit of %s is %lu \n", "test_data1",
		   find_next_zero_bit(&test_data1, 128, 0));
	// 基础测试
	SBIUNIT_EXPECT_EQ(test, find_next_zero_bit(&test_data1, 128, 0), 1);
	// 特定偏移量测试
	SBIUNIT_EXPECT_EQ(test, find_next_zero_bit(&test_data1, 128, 2), 3);
	SBIUNIT_EXPECT_EQ(test, find_next_zero_bit(&test_data1, 128, 64), 65);
	// 所有位都为0
	SBIUNIT_EXPECT_EQ(test, find_next_zero_bit(&test_data1, 128, 0), 0);
	// 所有位都为1
	SBIUNIT_EXPECT_EQ(test, find_next_zero_bit(&test_data1, 128, 0), 128);
	// 测试 offset >= size
	SBIUNIT_EXPECT_EQ(test, find_next_zero_bit(&test_data1, 128, 128), 128);
}

static struct sbiunit_test_case bitops_test_cases[] = {
	SBIUNIT_TEST_CASE(find_first_bit_test),
	SBIUNIT_TEST_CASE(find_first_zero_bit_test),
	SBIUNIT_TEST_CASE(find_last_bit_test),
	SBIUNIT_TEST_CASE(find_next_bit_test),
	SBIUNIT_TEST_CASE(find_next_zero_bit_test),
	SBIUNIT_END_CASE,
};

SBIUNIT_TEST_SUITE(bitops_test_suite, bitops_test_cases);
