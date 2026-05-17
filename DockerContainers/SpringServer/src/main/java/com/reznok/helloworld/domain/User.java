package com.reznok.helloworld.domain;

import javax.persistence.*;

@Entity
@Table(name = "spring_user")
public class User {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(unique = true, nullable = false)
    private String username;

    @Column(nullable = false)
    private String password;

    private String email;
    private String department;
    private String role; // "USER" or "ADMIN"

    public User() {}

    public User(Long id, String username, String password, String email,
                String department, String role) {
        this.id = id;
        this.username = username;
        this.password = password;
        this.email = email;
        this.department = department;
        this.role = role;
    }

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }

    public String getUsername() { return username; }
    public void setUsername(String username) { this.username = username; }

    public String getPassword() { return password; }
    public void setPassword(String password) { this.password = password; }

    public String getEmail() { return email; }
    public void setEmail(String email) { this.email = email; }

    public String getDepartment() { return department; }
    public void setDepartment(String department) { this.department = department; }

    public String getRole() { return role; }
    public void setRole(String role) { this.role = role; }
}
