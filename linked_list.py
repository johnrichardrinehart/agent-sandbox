"""Singly linked list with unit tests. Run: python linked_list.py"""
import unittest


class Node:
    def __init__(self, value, next=None):
        self.value = value
        self.next = next


class LinkedList:
    def __init__(self):
        self.head = None
        self._size = 0

    def __len__(self):
        return self._size

    def push_front(self, value):
        self.head = Node(value, self.head)
        self._size += 1

    def append(self, value):
        node = Node(value)
        if self.head is None:
            self.head = node
        else:
            cur = self.head
            while cur.next:
                cur = cur.next
            cur.next = node
        self._size += 1

    def find(self, value):
        cur = self.head
        while cur:
            if cur.value == value:
                return cur
            cur = cur.next
        return None

    def remove(self, value):
        prev, cur = None, self.head
        while cur:
            if cur.value == value:
                if prev is None:
                    self.head = cur.next
                else:
                    prev.next = cur.next
                self._size -= 1
                return True
            prev, cur = cur, cur.next
        return False

    def reverse(self):
        prev, cur = None, self.head
        while cur:
            cur.next, prev, cur = prev, cur, cur.next
        self.head = prev

    def to_list(self):
        out, cur = [], self.head
        while cur:
            out.append(cur.value)
            cur = cur.next
        return out


class LinkedListTests(unittest.TestCase):
    def test_empty(self):
        ll = LinkedList()
        self.assertEqual(len(ll), 0)
        self.assertEqual(ll.to_list(), [])

    def test_append_and_push_front(self):
        ll = LinkedList()
        ll.append(2)
        ll.append(3)
        ll.push_front(1)
        self.assertEqual(ll.to_list(), [1, 2, 3])
        self.assertEqual(len(ll), 3)

    def test_find(self):
        ll = LinkedList()
        for v in [1, 2, 3]:
            ll.append(v)
        self.assertEqual(ll.find(2).value, 2)
        self.assertIsNone(ll.find(99))

    def test_remove_head_middle_tail_missing(self):
        ll = LinkedList()
        for v in [1, 2, 3, 4]:
            ll.append(v)
        self.assertTrue(ll.remove(1))   # head
        self.assertTrue(ll.remove(3))   # middle
        self.assertTrue(ll.remove(4))   # tail
        self.assertFalse(ll.remove(99))  # missing
        self.assertEqual(ll.to_list(), [2])

    def test_reverse(self):
        ll = LinkedList()
        for v in [1, 2, 3]:
            ll.append(v)
        ll.reverse()
        self.assertEqual(ll.to_list(), [3, 2, 1])

    def test_reverse_empty_and_single(self):
        ll = LinkedList()
        ll.reverse()
        self.assertEqual(ll.to_list(), [])
        ll.append(1)
        ll.reverse()
        self.assertEqual(ll.to_list(), [1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
