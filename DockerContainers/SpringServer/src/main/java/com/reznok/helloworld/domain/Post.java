package com.reznok.helloworld.domain;

import java.time.LocalDateTime;

public class Post {

    private Long id;
    private String title;
    private String content;
    private String author;     // username of the writer
    private Long authorId;
    private String category;
    private LocalDateTime createdAt;
    private int views;

    public Post() {}

    public Post(Long id, String title, String content, String author,
                Long authorId, String category, LocalDateTime createdAt) {
        this.id = id;
        this.title = title;
        this.content = content;
        this.author = author;
        this.authorId = authorId;
        this.category = category;
        this.createdAt = createdAt;
        this.views = 0;
    }

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }

    public String getTitle() { return title; }
    public void setTitle(String title) { this.title = title; }

    public String getContent() { return content; }
    public void setContent(String content) { this.content = content; }

    public String getAuthor() { return author; }
    public void setAuthor(String author) { this.author = author; }

    public Long getAuthorId() { return authorId; }
    public void setAuthorId(Long authorId) { this.authorId = authorId; }

    public String getCategory() { return category; }
    public void setCategory(String category) { this.category = category; }

    public LocalDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(LocalDateTime createdAt) { this.createdAt = createdAt; }

    public int getViews() { return views; }
    public void setViews(int views) { this.views = views; }
}
