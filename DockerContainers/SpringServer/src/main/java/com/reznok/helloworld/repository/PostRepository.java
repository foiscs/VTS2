package com.reznok.helloworld.repository;

import com.reznok.helloworld.domain.Post;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

@Repository
public class PostRepository {

    private final Map<Long, Post> store = new ConcurrentHashMap<>();
    private final AtomicLong sequence = new AtomicLong(0);

    public Post save(Post p) {
        if (p.getId() == null) {
            p.setId(sequence.incrementAndGet());
            if (p.getCreatedAt() == null) {
                p.setCreatedAt(LocalDateTime.now());
            }
        }
        store.put(p.getId(), p);
        return p;
    }

    public Optional<Post> findById(Long id) {
        return Optional.ofNullable(store.get(id));
    }

    public List<Post> findAll() {
        List<Post> all = new ArrayList<>(store.values());
        all.sort((a, b) -> b.getId().compareTo(a.getId()));
        return all;
    }

    public void deleteById(Long id) {
        store.remove(id);
    }
}
