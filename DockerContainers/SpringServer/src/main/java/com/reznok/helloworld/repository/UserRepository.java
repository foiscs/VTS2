package com.reznok.helloworld.repository;

import com.reznok.helloworld.domain.User;
import org.springframework.stereotype.Repository;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

@Repository
public class UserRepository {

    private final Map<Long, User> store = new ConcurrentHashMap<>();
    private final AtomicLong sequence = new AtomicLong(0);

    public User save(User u) {
        if (u.getId() == null) {
            u.setId(sequence.incrementAndGet());
        }
        store.put(u.getId(), u);
        return u;
    }

    public Optional<User> findById(Long id) {
        return Optional.ofNullable(store.get(id));
    }

    public Optional<User> findByUsername(String username) {
        return store.values().stream()
                .filter(u -> u.getUsername().equals(username))
                .findFirst();
    }

    public List<User> findAll() {
        List<User> all = new ArrayList<>(store.values());
        all.sort(Comparator.comparing(User::getId));
        return all;
    }
}
