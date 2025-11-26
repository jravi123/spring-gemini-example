package com.example.demo;
import com.google.cloud.spring.data.datastore.core.mapping.Entity;
import org.springframework.data.annotation.Id;

@Entity(name = "User")
public class User{

    @Id
    private Long Id;

    private String firstName;
    private String lastName;


    public Long getId() {
        return Id;
    }
    public String getFirstName() {
        return firstName;
    }
    public String getLastName() {
        return lastName;
    }


    public void setFirstName(String firstName) {
        this.firstName = firstName;
    }


    public void setLastName(String lastName) {
        this.lastName = lastName;
    }
    

}